defmodule Clubeira.Redemptions.ValidationPointProvisioner do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Place
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Redemptions.ValidationPointProvisionRequest
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "redemptions.provision_validation_point"
  @maximum_credential_lifetime_seconds 365 * 24 * 60 * 60
  @replay_reasons %{"credential_already_registered" => :credential_already_registered}

  @type result :: %{String.t() => term()}

  @spec provision(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def provision(%Scope{actor_user_id: nil}, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  def provision(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, request} <- ValidationPointProvisionRequest.new(attributes) do
      scope
      |> transact_provisioning(place_id, request)
      |> unwrap_transaction()
    end
  end

  def provision(_scope, _place_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_provisioning(scope, place_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        repo
        |> reserve_provisioning(scope, place_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_provisioning(repo, scope, place_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, place_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        with {:ok, participation} <- fetch_active_participation(repo, scope, place_id),
             :ok <- validate_expiration(request.expires_at, now) do
          provision_new(repo, scope, place_id, participation, request, idempotency_id, now)
        end

      {:replay, key} ->
        replay(repo, key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provision_new(repo, scope, place_id, participation, request, idempotency_id, now) do
    validation_point =
      %ValidationPoint{
        polo_id: scope.polo_id,
        polo_place_id: participation.id,
        name: request.name,
        kind: "api",
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    case insert_credential(repo, scope, validation_point, request, now) do
      {:ok, credential} ->
        complete_provisioning!(
          repo,
          scope,
          place_id,
          validation_point,
          credential,
          idempotency_id,
          now
        )

      {:error, %Ecto.Changeset{}} ->
        repo.delete!(validation_point)
        reject!(repo, scope, idempotency_id, :credential_already_registered, now)
    end
  end

  defp insert_credential(repo, scope, validation_point, request, now) do
    %ValidationCredential{
      polo_id: scope.polo_id,
      validation_point_id: validation_point.id,
      version: 1,
      kind: "api_key",
      secret_hash: ValidationPointProvisionRequest.secret_hash(request),
      valid_during: active_range(now, request.expires_at),
      status: "active",
      inserted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:secret_hash,
      name: :validation_credentials_secret_hash_uidx
    )
    |> repo.insert(mode: :savepoint)
  end

  defp complete_provisioning!(
         repo,
         scope,
         place_id,
         validation_point,
         credential,
         idempotency_id,
         now
       ) do
    result = response_data(place_id, validation_point, credential)

    record_provisioning!(repo, scope, place_id, validation_point, credential, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "validation_point",
      validation_point.id,
      result,
      now
    )

    {:accepted, result}
  end

  defp record_provisioning!(repo, scope, place_id, point, credential, now) do
    payload = %{
      "validation_point_id" => point.id,
      "validation_credential_id" => credential.id,
      "polo_place_id" => point.polo_place_id,
      "place_id" => place_id,
      "point_kind" => point.kind,
      "credential_kind" => credential.kind,
      "credential_version" => credential.version,
      "credential_expires_at" => DateTime.to_iso8601(credential.valid_during.upper),
      "provisioned_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "validation_point",
      aggregate_id: point.id,
      aggregate_version: 1,
      event_type: "validation_point.provisioned",
      topic: "redemptions.validation_points.provisioned",
      message_key: point.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "validation_point.provisioned",
      resource_type: "validation_point",
      resource_id: point.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp fetch_active_polo(repo, polo_id) do
    polo =
      Polo
      |> where([polo], polo.id == ^polo_id)
      |> lock("FOR SHARE")
      |> repo.one()

    case polo do
      %Polo{status: "active"} -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp fetch_active_participation(repo, scope, place_id) do
    participation =
      PoloPlace
      |> where([polo_place], polo_place.polo_id == ^scope.polo_id)
      |> where([polo_place], polo_place.place_id == ^place_id and polo_place.status == "active")
      |> where(
        [polo_place],
        fragment("? @> statement_timestamp()", polo_place.participation_during)
      )
      |> lock("FOR SHARE")
      |> repo.one()

    case participation do
      %PoloPlace{} -> ensure_active_place(repo, participation)
      nil -> {:error, :place_not_found}
    end
  end

  defp ensure_active_place(repo, participation) do
    active_place =
      Place
      |> where([place], place.id == ^participation.place_id and place.status == "active")
      |> lock("FOR SHARE")
      |> repo.one()

    if active_place, do: {:ok, participation}, else: {:error, :place_not_found}
  end

  defp validate_expiration(expires_at, now) do
    lifetime_seconds = DateTime.diff(expires_at, now, :second)

    if lifetime_seconds in 1..@maximum_credential_lifetime_seconds,
      do: :ok,
      else: {:error, :invalid_expiration}
  end

  defp replay(
         _repo,
         %Key{
           status: "completed",
           response_status: 201,
           resource_type: "validation_point",
           response_body:
             %{
               "id" => point_id,
               "credential" => %{"id" => credential_id}
             } = response_body
         }
       )
       when is_binary(point_id) and is_binary(credential_id),
       do: {:accepted, response_body}

  defp replay(
         _repo,
         %Key{status: "failed", response_body: %{"reason" => reason}}
       ) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key),
    do: raise("invalid persisted validation point response: #{inspect(key)}")

  defp reject!(repo, scope, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now, response_status: 409)

    Audit.record_tenant!(repo, scope, %{
      action: "validation_point.provisioning_rejected",
      resource_type: "validation_point_provisioning",
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp request_hash(scope, place_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      place_id,
      request.name,
      ValidationPointProvisionRequest.secret_hash(request),
      request.expires_at
    })
  end

  defp active_range(now, expires_at) do
    %Postgrex.Range{
      lower: now,
      upper: expires_at,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp response_data(place_id, validation_point, credential) do
    %{
      "id" => validation_point.id,
      "place_id" => place_id,
      "polo_place_id" => validation_point.polo_place_id,
      "name" => validation_point.name,
      "kind" => validation_point.kind,
      "status" => validation_point.status,
      "credential" => %{
        "id" => credential.id,
        "version" => credential.version,
        "kind" => credential.kind,
        "status" => credential.status,
        "valid_from" => DateTime.to_iso8601(credential.valid_during.lower),
        "expires_at" => DateTime.to_iso8601(credential.valid_during.upper)
      }
    }
  end

  defp cast_place_id(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :place_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
