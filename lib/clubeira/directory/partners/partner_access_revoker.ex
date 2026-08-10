defmodule Clubeira.Directory.PartnerAccessRevoker do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.PartnerAccessRevocationRequest
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "directory.revoke_partner_access"
  @role_key "partner_manager"
  @replay_reasons %{
    "partner_access_revoked" => :partner_access_revoked,
    "partner_access_unavailable" => :partner_access_unavailable
  }

  @type result :: %{String.t() => term()}

  @spec revoke(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def revoke(%Scope{actor_user_id: nil}, _access_id, _attributes),
    do: {:error, :partner_admin_required}

  def revoke(%Scope{} = scope, access_id, attributes) when is_map(attributes) do
    with {:ok, access_id} <- cast_access_id(access_id),
         {:ok, request} <- PartnerAccessRevocationRequest.new(attributes) do
      scope
      |> transact_revocation(access_id, request)
      |> unwrap_transaction()
    end
  end

  def revoke(_scope, _access_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_revocation(scope, access_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        repo
        |> reserve_revocation(scope, access_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_revocation(repo, scope, access_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, access_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        revoke_new(repo, scope, access_id, request, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_new(repo, scope, access_id, request, idempotency_id) do
    with {:ok, membership} <- lock_partner_membership(repo, scope, access_id) do
      now = transaction_time(repo)

      case revoke_membership(repo, membership, now) do
        {:ok, revoked} ->
          complete_revocation!(repo, scope, revoked, request, idempotency_id, now)

        {:error, reason} ->
          reject!(repo, scope, membership, request, idempotency_id, reason, now)
      end
    end
  end

  defp lock_partner_membership(repo, scope, access_id) do
    membership =
      PoloMembership
      |> where(
        [membership],
        membership.id == ^access_id and membership.polo_id == ^scope.polo_id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    with %PoloMembership{} = membership <- membership,
         true <- partner_membership?(repo, scope, membership.id) do
      {:ok, membership}
    else
      _missing_or_not_partner -> {:error, :partner_access_not_found}
    end
  end

  defp partner_membership?(repo, scope, membership_id) do
    PoloMembershipRole
    |> join(:inner, [assignment], role in PoloRole,
      on: role.id == assignment.polo_role_id and role.polo_id == assignment.polo_id
    )
    |> where(
      [assignment],
      assignment.polo_id == ^scope.polo_id and
        assignment.polo_membership_id == ^membership_id
    )
    |> where([_assignment, role], role.key == @role_key)
    |> select([_assignment, role], role.id)
    |> limit(1)
    |> lock("FOR SHARE")
    |> repo.one()
    |> is_binary()
  end

  defp revoke_membership(repo, membership, now) do
    cond do
      membership.status == "revoked" ->
        {:error, :partner_access_revoked}

      membership.status == "active" and active_at?(membership.valid_during, now) ->
        membership
        |> Ecto.Changeset.change(%{
          status: "revoked",
          valid_during: close_range(membership.valid_during, now),
          updated_at: now
        })
        |> repo.update()

      true ->
        {:error, :partner_access_unavailable}
    end
  end

  defp complete_revocation!(repo, scope, membership, request, idempotency_id, now) do
    result = response_data(membership)

    record_revocation!(repo, scope, membership, request, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "partner_access",
      membership.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_revocation!(repo, scope, membership, request, now) do
    payload = %{
      "partner_access_id" => membership.id,
      "user_id" => membership.user_id,
      "status" => membership.status,
      "revoked_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "partner_access",
      aggregate_id: membership.id,
      aggregate_version: 2,
      event_type: "partner_access.revoked",
      topic: "partners.access.revoked",
      message_key: membership.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "partner_access.revoked",
      resource_type: "partner_access",
      resource_id: membership.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp reject!(repo, scope, membership, request, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "partner_access",
      membership.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "partner_access.revocation_rejected",
      resource_type: "partner_access",
      resource_id: membership.id,
      metadata: %{
        "current_status" => membership.status,
        "reason" => Atom.to_string(reason),
        "operator_reason" => request.reason
      },
      occurred_at: now
    })

    {:denied, reason}
  end

  defp response_data(membership) do
    %{
      "id" => membership.id,
      "role" => @role_key,
      "status" => membership.status,
      "user_id" => membership.user_id,
      "valid_until" => DateTime.to_iso8601(membership.valid_during.upper)
    }
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "partner_access",
         response_body:
           %{"id" => access_id, "status" => "revoked", "user_id" => user_id} = response_body
       })
       when is_binary(access_id) and is_binary(user_id),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key), do: raise("invalid persisted partner access revocation: #{inspect(key)}")

  defp request_hash(scope, access_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      access_id,
      request.reason
    })
  end

  defp active_at?(%Postgrex.Range{lower: lower, upper: :unbound}, now),
    do: DateTime.compare(lower, now) in [:lt, :eq]

  defp active_at?(%Postgrex.Range{lower: lower, upper: upper}, now) do
    DateTime.compare(lower, now) in [:lt, :eq] and DateTime.compare(now, upper) == :lt
  end

  defp close_range(range, now), do: %{range | upper: now, upper_inclusive: false}

  defp fetch_active_polo(repo, polo_id) do
    case Polo |> where([polo], polo.id == ^polo_id) |> lock("FOR SHARE") |> repo.one() do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp cast_access_id(access_id) do
    case Ecto.UUID.cast(access_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :partner_access_not_found}
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
