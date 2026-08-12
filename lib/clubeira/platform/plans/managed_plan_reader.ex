defmodule Clubeira.Platform.ManagedPlanReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Platform.Authorization
  alias Clubeira.Platform.Feature
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PlanVersionFeature
  alias Clubeira.Platform.Price
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @default_page_limit 20
  @maximum_page_limit 100

  @spec list(ActorScope.t(), map()) ::
          {:ok, %{plans: [map()], page: map()}}
          | {:error,
             :invalid_actor_scope | :invalid_pagination | :platform_billing_admin_required}
  def list(%ActorScope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params) do
      Repo.transact_as_actor(scope, &list_authorized(&1, scope, pagination))
    end
  end

  def list(%ActorScope{}, _params), do: {:error, :invalid_pagination}
  def list(_scope, _params), do: {:error, :invalid_actor_scope}

  defp list_authorized(repo, scope, pagination) do
    with :ok <-
           Authorization.authorize(
             repo,
             scope,
             :manage_platform_billing,
             transaction_time(repo)
           ) do
      {:ok, managed_plan_page(repo, pagination)}
    end
  end

  defp managed_plan_page(repo, pagination) do
    rows =
      Plan
      |> after_plan(pagination.after)
      |> order_by([plan], desc: plan.inserted_at, desc: plan.id)
      |> select([plan], %{
        id: plan.id,
        code: plan.code,
        name: plan.name,
        status: plan.status,
        recorded_at: plan.inserted_at,
        updated_at: plan.updated_at
      })
      |> limit(^(pagination.limit + 1))
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    versions = versions_by_plan(repo, Enum.map(page_rows, & &1.id))

    %{
      plans:
        Enum.map(page_rows, fn plan ->
          Map.put(plan, :versions, Map.get(versions, plan.id, []))
        end),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp versions_by_plan(_repo, []), do: %{}

  defp versions_by_plan(repo, plan_ids) do
    versions =
      PlanVersion
      |> where([version], version.platform_plan_id in ^plan_ids)
      |> order_by([version], asc: version.platform_plan_id, desc: version.version)
      |> select([version], %{
        id: version.id,
        platform_plan_id: version.platform_plan_id,
        version: version.version,
        name: version.name,
        description: version.description,
        status: version.status,
        published_at: version.published_at,
        recorded_at: version.inserted_at
      })
      |> repo.all()

    version_ids = Enum.map(versions, & &1.id)
    prices = prices_by_version(repo, version_ids)
    features = features_by_version(repo, version_ids)

    Enum.group_by(versions, & &1.platform_plan_id, fn version ->
      version
      |> Map.delete(:platform_plan_id)
      |> Map.put(:features, Map.get(features, version.id, []))
      |> Map.put(:prices, Map.get(prices, version.id, []))
    end)
  end

  defp prices_by_version(_repo, []), do: %{}

  defp prices_by_version(repo, version_ids) do
    Price
    |> where([price], price.platform_plan_version_id in ^version_ids)
    |> order_by([price],
      asc: price.platform_plan_version_id,
      asc: price.currency,
      asc: price.inserted_at,
      asc: price.id
    )
    |> select([price], %{
      id: price.id,
      platform_plan_version_id: price.platform_plan_version_id,
      currency: price.currency,
      amount: price.amount,
      billing_interval_unit: price.billing_interval_unit,
      billing_interval_count: price.billing_interval_count,
      valid_during: price.valid_during,
      recorded_at: price.inserted_at
    })
    |> repo.all()
    |> Enum.group_by(
      & &1.platform_plan_version_id,
      &Map.delete(&1, :platform_plan_version_id)
    )
  end

  defp features_by_version(_repo, []), do: %{}

  defp features_by_version(repo, version_ids) do
    PlanVersionFeature
    |> join(:inner, [assignment], feature in Feature,
      on:
        feature.id == assignment.platform_feature_id and
          feature.value_kind == assignment.value_kind
    )
    |> where([assignment], assignment.platform_plan_version_id in ^version_ids)
    |> order_by([assignment, feature],
      asc: assignment.platform_plan_version_id,
      asc: feature.key
    )
    |> select([assignment, feature], %{
      platform_plan_version_id: assignment.platform_plan_version_id,
      key: feature.key,
      name: feature.name,
      status: feature.status,
      value_kind: assignment.value_kind,
      boolean_value: assignment.boolean_value,
      integer_value: assignment.integer_value
    })
    |> repo.all()
    |> Enum.group_by(
      & &1.platform_plan_version_id,
      &Map.delete(&1, :platform_plan_version_id)
    )
  end

  defp after_plan(query, nil), do: query

  defp after_plan(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [plan],
      plan.inserted_at < ^recorded_at or
        (plan.inserted_at == ^recorded_at and plan.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_plan} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_plan}}
    else
      :error -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_page_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_limit(_limit), do: :error

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, <<unix_microsecond::signed-64, plan_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(plan_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_plans, false), do: nil

  defp next_cursor(plans, true) do
    %{recorded_at: recorded_at, id: id} = List.last(plans)

    <<DateTime.to_unix(recorded_at, :microsecond)::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
