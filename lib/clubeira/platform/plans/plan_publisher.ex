defmodule Clubeira.Platform.PlanPublisher do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.Idempotency
  alias Clubeira.Platform.Authorization
  alias Clubeira.Platform.Feature
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanPublishRequest
  alias Clubeira.Platform.PlanReader
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PlanVersionFeature
  alias Clubeira.Platform.Price
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @code_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @spec publish(ActorScope.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def publish(%ActorScope{} = scope, code, version_number, attributes)
      when is_binary(code) and is_integer(version_number) and is_map(attributes) do
    code = String.trim(code)

    with :ok <- validate_identity(code, version_number),
         {:ok, request} <- PlanPublishRequest.new(attributes) do
      Repo.transact_as_actor(
        scope,
        &publish_in_scope(&1, scope, code, version_number, request)
      )
    end
  end

  def publish(%ActorScope{}, _code, _version, attributes),
    do: PlanPublishRequest.new(attributes)

  def publish(_scope, _code, _version, _attributes), do: {:error, :invalid_actor_scope}

  defp publish_in_scope(repo, scope, code, version_number, request) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_platform_billing, now) do
      lock_code!(repo, code)
      publish_locked(repo, scope, code, version_number, request, now)
    end
  end

  defp publish_locked(repo, scope, code, version_number, request, now) do
    plan = lock_plan(repo, code)

    case load_version(repo, plan, version_number) do
      %PlanVersion{} = version ->
        replay(repo, plan, version, request)

      nil ->
        with {:ok, plan} <- ensure_plan(repo, plan, code, version_number, request, now),
             :ok <- require_next_version(repo, plan, version_number),
             {:ok, version} <- insert_version(repo, plan, version_number, request, now),
             :ok <- insert_features(repo, version, request.features, now),
             {:ok, _price} <- insert_price(repo, version, request, now) do
          record_publication!(repo, scope, plan, version, request, now)
          {:ok, PlanReader.persisted_view(repo, plan, version)}
        end
    end
  end

  defp replay(repo, plan, version, request) do
    if persisted_fingerprint(repo, plan, version) == request_fingerprint(request) do
      {:ok, PlanReader.persisted_view(repo, plan, version)}
    else
      {:error, :platform_plan_version_conflict}
    end
  end

  defp ensure_plan(repo, nil, code, 1, request, now) do
    %Plan{
      code: code,
      name: request.name,
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert()
  end

  defp ensure_plan(_repo, nil, _code, _version_number, _request, _now),
    do: {:error, :platform_plan_version_gap}

  defp ensure_plan(repo, %Plan{} = plan, _code, _version_number, request, now) do
    cond do
      plan.status == "retired" ->
        {:error, :platform_plan_retired}

      plan.name == request.name and plan.status == "active" ->
        {:ok, plan}

      true ->
        plan
        |> Ecto.Changeset.change(name: request.name, status: "active", updated_at: now)
        |> repo.update()
    end
  end

  defp require_next_version(repo, plan, version_number) do
    current =
      PlanVersion
      |> where([version], version.platform_plan_id == ^plan.id)
      |> repo.aggregate(:max, :version)

    if version_number == (current || 0) + 1,
      do: :ok,
      else: {:error, :platform_plan_version_gap}
  end

  defp insert_version(repo, plan, version_number, request, now) do
    %PlanVersion{
      platform_plan_id: plan.id,
      version: version_number,
      name: request.version_name,
      description: request.description,
      status: "published",
      published_at: now,
      inserted_at: now
    }
    |> repo.insert()
  end

  defp insert_features(repo, version, features, now) do
    Enum.reduce_while(features, :ok, fn requested, :ok ->
      with {:ok, feature} <- ensure_feature(repo, requested, now),
           {:ok, _assignment} <- insert_feature_value(repo, version, feature, requested, now) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_feature(repo, requested, now) do
    case repo.one(
           from(feature in Feature, where: feature.key == ^requested.key, lock: "FOR SHARE")
         ) do
      nil ->
        %Feature{
          key: requested.key,
          name: requested.name,
          value_kind: requested.value_kind,
          status: "active",
          inserted_at: now,
          updated_at: now
        }
        |> repo.insert()

      %Feature{name: name, value_kind: kind, status: "active"} = feature
      when name == requested.name and kind == requested.value_kind ->
        {:ok, feature}

      %Feature{} ->
        {:error, :platform_feature_conflict}
    end
  end

  defp insert_feature_value(repo, version, feature, requested, now) do
    %PlanVersionFeature{
      platform_plan_version_id: version.id,
      platform_feature_id: feature.id,
      value_kind: requested.value_kind,
      boolean_value: requested.boolean_value,
      integer_value: requested.integer_value,
      inserted_at: now
    }
    |> repo.insert()
  end

  defp insert_price(repo, version, request, now) do
    %Price{
      platform_plan_version_id: version.id,
      currency: request.currency,
      amount: request.amount,
      billing_interval_unit: request.billing_interval_unit,
      billing_interval_count: request.billing_interval_count,
      valid_during: closed_range(request.valid_from, request.valid_until),
      inserted_at: now
    }
    |> repo.insert()
  end

  defp record_publication!(repo, scope, plan, version, request, now) do
    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: "platform_plan_version.published",
      resource_type: "platform_plan_version",
      resource_id: version.id,
      metadata: %{
        "platform_plan_id" => plan.id,
        "code" => plan.code,
        "version" => version.version,
        "currency" => request.currency,
        "amount" => Decimal.to_string(request.amount),
        "feature_count" => length(request.features)
      },
      occurred_at: now
    })
  end

  defp lock_plan(repo, code) do
    repo.one(from(plan in Plan, where: plan.code == ^code, lock: "FOR UPDATE"))
  end

  defp load_version(_repo, nil, _version_number), do: nil

  defp load_version(repo, plan, version_number) do
    repo.one(
      from(version in PlanVersion,
        where: version.platform_plan_id == ^plan.id and version.version == ^version_number,
        lock: "FOR SHARE"
      )
    )
  end

  defp persisted_fingerprint(repo, plan, version) do
    view = PlanReader.persisted_view(repo, plan, version)
    request_fingerprint(view_request(view))
  end

  defp view_request(view) do
    price = view.version.price

    %{
      name: view.name,
      version_name: view.version.name,
      description: view.version.description,
      currency: price.currency,
      amount: price.amount,
      billing_interval_unit: price.billing_interval_unit,
      billing_interval_count: price.billing_interval_count,
      valid_from: price.valid_during.lower,
      valid_until: price.valid_during.upper,
      features: view.version.features
    }
  end

  defp request_fingerprint(request) do
    Idempotency.fingerprint({
      1,
      request.name,
      request.version_name,
      request.description,
      request.currency,
      Decimal.to_string(request.amount),
      request.billing_interval_unit,
      request.billing_interval_count,
      DateTime.to_iso8601(request.valid_from),
      DateTime.to_iso8601(request.valid_until),
      Enum.map(request.features, fn feature ->
        {
          feature.key,
          feature.name,
          feature.value_kind,
          feature.boolean_value,
          feature.integer_value
        }
      end)
    })
  end

  defp validate_identity(code, version_number) do
    if byte_size(code) in 2..80 and Regex.match?(@code_pattern, code) and version_number > 0,
      do: :ok,
      else: {:error, :invalid_platform_plan_identity}
  end

  defp lock_code!(repo, code) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [code])
    :ok
  end

  defp closed_range(lower, upper) do
    %Postgrex.Range{
      lower: lower,
      upper: upper,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
