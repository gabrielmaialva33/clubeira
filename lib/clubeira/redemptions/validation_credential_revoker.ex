defmodule Clubeira.Redemptions.ValidationCredentialRevoker do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationCredentialRevocationRequest
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "redemptions.revoke_validation_credential"
  @lifecycle_lock_prefix "validation-credential-lifecycle:"
  @replay_reasons %{
    "validation_credential_revoked" => :validation_credential_revoked,
    "validation_credential_stale" => :validation_credential_stale,
    "validation_credential_unavailable" => :validation_credential_unavailable
  }

  @type result :: %{String.t() => term()}

  @spec revoke(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def revoke(%Scope{actor_user_id: nil}, _credential_id, _attributes),
    do: {:error, :partner_admin_required}

  def revoke(%Scope{} = scope, credential_id, attributes) when is_map(attributes) do
    with {:ok, credential_id} <- cast_credential_id(credential_id),
         {:ok, request} <- ValidationCredentialRevocationRequest.new(attributes) do
      scope
      |> transact_revocation(credential_id, request)
      |> unwrap_transaction()
    end
  end

  def revoke(_scope, _credential_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_revocation(scope, credential_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      authorization_time = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, authorization_time) do
        repo
        |> reserve_revocation(scope, credential_id, request, authorization_time)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_revocation(repo, scope, credential_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, credential_id),
           now
         ) do
      {:new, idempotency_id} ->
        revoke_new(repo, scope, credential_id, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_new(repo, scope, credential_id, idempotency_id) do
    with {:ok, target} <- fetch_target_credential(repo, scope, credential_id),
         :ok <- lock_lifecycle(repo, target.validation_point_id),
         {:ok, point} <- lock_point(repo, scope, target.validation_point_id),
         now = transaction_time(repo),
         {:ok, current} <- lock_current_credential(repo, scope, point.id),
         :ok <-
           ensure_current_target(repo, scope, current, target, idempotency_id, now),
         {:ok, revoked} <-
           revoke_current(repo, scope, current, idempotency_id, now) do
      complete_revocation!(repo, scope, point, revoked, idempotency_id, now)
    end
  end

  defp fetch_target_credential(repo, scope, credential_id) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.id == ^credential_id and credential.polo_id == ^scope.polo_id and
          credential.kind == "api_key"
      )
      |> repo.one()

    case credential do
      %ValidationCredential{} -> {:ok, credential}
      nil -> {:error, :validation_credential_not_found}
    end
  end

  defp lock_lifecycle(repo, validation_point_id) do
    lock_key = @lifecycle_lock_prefix <> validation_point_id
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])
    :ok
  end

  defp lock_point(repo, scope, validation_point_id) do
    point =
      ValidationPoint
      |> where(
        [point],
        point.id == ^validation_point_id and point.polo_id == ^scope.polo_id and
          point.kind == "api"
      )
      |> lock("FOR SHARE")
      |> repo.one()

    case point do
      %ValidationPoint{} -> {:ok, point}
      nil -> {:error, :validation_point_not_found}
    end
  end

  defp lock_current_credential(repo, scope, validation_point_id) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.polo_id == ^scope.polo_id and
          credential.validation_point_id == ^validation_point_id and
          credential.kind == "api_key"
      )
      |> order_by([credential], desc: credential.version)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> repo.one()

    case credential do
      %ValidationCredential{} -> {:ok, credential}
      nil -> {:error, :validation_credential_not_found}
    end
  end

  defp ensure_current_target(
         _repo,
         _scope,
         %ValidationCredential{id: id},
         %ValidationCredential{id: id},
         _idempotency_id,
         _now
       ),
       do: :ok

  defp ensure_current_target(repo, scope, _current, target, idempotency_id, now) do
    reject!(repo, scope, target, idempotency_id, :validation_credential_stale, now)
  end

  defp revoke_current(repo, scope, credential, idempotency_id, now) do
    cond do
      credential.status == "revoked" ->
        reject!(
          repo,
          scope,
          credential,
          idempotency_id,
          :validation_credential_revoked,
          now
        )

      credential.status == "active" and active_at?(credential.valid_during, now) ->
        revoked =
          credential
          |> Ecto.Changeset.change(
            status: "revoked",
            valid_during: close_range(credential.valid_during, now)
          )
          |> repo.update!()

        {:ok, revoked}

      true ->
        reject!(
          repo,
          scope,
          credential,
          idempotency_id,
          :validation_credential_unavailable,
          now
        )
    end
  end

  defp complete_revocation!(repo, scope, point, credential, idempotency_id, now) do
    result = response_data(point, credential)

    record_revocation!(repo, scope, point, credential, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "validation_credential",
      credential.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_revocation!(repo, scope, point, credential, now) do
    payload = %{
      "validation_credential_id" => credential.id,
      "validation_point_id" => point.id,
      "credential_kind" => credential.kind,
      "credential_version" => credential.version,
      "revoked_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "validation_credential",
      aggregate_id: credential.id,
      aggregate_version: 1,
      event_type: "validation_credential.revoked",
      topic: "redemptions.validation_credentials.revoked",
      message_key: credential.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "validation_credential.revoked",
      resource_type: "validation_credential",
      resource_id: credential.id,
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

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "validation_credential",
         response_body:
           %{
             "validation_point_id" => point_id,
             "credential" => %{"id" => credential_id, "status" => "revoked"}
           } = response_body
       })
       when is_binary(point_id) and is_binary(credential_id),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key),
    do: raise("invalid persisted validation credential revocation response: #{inspect(key)}")

  defp request_hash(scope, credential_id) do
    Idempotency.fingerprint({1, scope.polo_id, scope.actor_user_id, credential_id})
  end

  defp reject!(repo, scope, credential, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "validation_credential",
      credential.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "validation_credential.revocation_rejected",
      resource_type: "validation_credential",
      resource_id: credential.id,
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp active_at?(%Postgrex.Range{lower: lower, upper: :unbound}, now),
    do: DateTime.compare(lower, now) in [:lt, :eq]

  defp active_at?(%Postgrex.Range{lower: lower, upper: upper}, now) do
    DateTime.compare(lower, now) in [:lt, :eq] and DateTime.compare(now, upper) == :lt
  end

  defp close_range(range, now), do: %{range | upper: now, upper_inclusive: false}

  defp response_data(point, credential) do
    %{
      "validation_point_id" => point.id,
      "credential" => %{
        "id" => credential.id,
        "version" => credential.version,
        "kind" => credential.kind,
        "status" => credential.status,
        "valid_from" => DateTime.to_iso8601(credential.valid_during.lower),
        "valid_until" => DateTime.to_iso8601(credential.valid_during.upper)
      }
    }
  end

  defp cast_credential_id(credential_id) do
    case Ecto.UUID.cast(credential_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :validation_credential_not_found}
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
