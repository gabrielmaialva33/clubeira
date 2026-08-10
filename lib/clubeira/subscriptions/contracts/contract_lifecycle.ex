defmodule Clubeira.Subscriptions.ContractLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Subscriptions.ContractLifecycleRequest
  alias Clubeira.Subscriptions.ContractSuspension
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "subscriptions.transition_contract"
  @replay_reasons %{
    "invalid_access_contract_transition" => :invalid_access_contract_transition
  }

  @type result :: %{String.t() => term()}

  @spec transition(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(%Scope{actor_user_id: nil}, _contract_id, _attributes),
    do: {:error, :billing_admin_required}

  def transition(%Scope{} = scope, contract_id, attributes) when is_map(attributes) do
    with {:ok, contract_id} <- cast_contract_id(contract_id),
         {:ok, request} <- ContractLifecycleRequest.new(attributes) do
      scope
      |> transact_transition(contract_id, request)
      |> unwrap_transaction()
    end
  end

  def transition(_scope, _contract_id, _attributes),
    do: {:error, :billing_admin_required}

  defp transact_transition(scope, contract_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_billing, now) do
        repo
        |> reserve_transition(scope, contract_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp reserve_transition(repo, scope, contract_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, contract_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        transition_new(repo, scope, contract_id, request, idempotency_id, now)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition_new(repo, scope, contract_id, request, idempotency_id, now) do
    with {:ok, contract} <- lock_contract(repo, scope, contract_id) do
      case apply_transition(repo, scope, contract, request, now) do
        {:ok, updated, event} ->
          complete_transition!(
            repo,
            scope,
            contract,
            updated,
            event,
            request,
            idempotency_id,
            now
          )

        {:error, reason} ->
          reject!(repo, scope, contract, request, idempotency_id, reason, now)
      end
    end
  end

  defp apply_transition(repo, scope, %AccessContract{status: status} = contract, request, now)
       when status in ["active", "past_due"] and request.action == "suspend" do
    updated = update_contract_status!(repo, contract, "suspended", now)
    event = insert_contract_event!(repo, scope, contract, updated, request.action, now)
    insert_suspension!(repo, scope, contract, event, request.reason, now)
    {:ok, updated, event}
  end

  defp apply_transition(
         repo,
         scope,
         %AccessContract{status: "suspended"} = contract,
         request,
         now
       )
       when request.action == "reactivate" do
    case lock_open_suspension(repo, scope, contract.id) do
      %ContractSuspension{} = suspension ->
        close_suspension!(repo, suspension, now)
        updated = update_contract_status!(repo, contract, "active", now)
        event = insert_contract_event!(repo, scope, contract, updated, request.action, now)
        {:ok, updated, event}

      nil ->
        {:error, :invalid_access_contract_transition}
    end
  end

  defp apply_transition(_repo, _scope, _contract, _request, _now),
    do: {:error, :invalid_access_contract_transition}

  defp lock_contract(repo, scope, contract_id) do
    contract =
      AccessContract
      |> where(
        [contract],
        contract.id == ^contract_id and contract.polo_id == ^scope.polo_id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    if contract, do: {:ok, contract}, else: {:error, :access_contract_not_found}
  end

  defp lock_open_suspension(repo, scope, contract_id) do
    ContractSuspension
    |> where(
      [suspension],
      suspension.polo_id == ^scope.polo_id and
        suspension.access_contract_id == ^contract_id and
        fragment("upper_inf(?)", suspension.suspended_during)
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp update_contract_status!(repo, contract, status, now) do
    contract
    |> Ecto.Changeset.change(status: status, updated_at: now)
    |> repo.update!()
  end

  defp insert_contract_event!(repo, scope, previous, contract, action, now) do
    sequence = next_event_sequence(repo, scope, contract.id)

    %ContractEvent{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      sequence: sequence,
      event_type: event_name(action),
      actor_user_id: scope.actor_user_id,
      payload: %{
        "previous_status" => previous.status,
        "status" => contract.status
      },
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_suspension!(repo, scope, contract, event, reason, now) do
    %ContractSuspension{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      source_contract_event_id: event.id,
      reason: reason,
      suspended_during: open_range(now),
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp close_suspension!(repo, suspension, now) do
    range = suspension.suspended_during

    suspension
    |> Ecto.Changeset.change(
      suspended_during: %Postgrex.Range{
        lower: range.lower,
        upper: now,
        lower_inclusive: true,
        upper_inclusive: false
      }
    )
    |> repo.update!()
  end

  defp complete_transition!(
         repo,
         scope,
         previous,
         contract,
         event,
         request,
         idempotency_id,
         now
       ) do
    result = response_data(previous, contract, event, request, now)
    record_transition!(repo, scope, previous, contract, event, request, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "access_contract",
      contract.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_transition!(repo, scope, previous, contract, event, request, now) do
    name = event_name(request.action)

    payload = %{
      "access_contract_id" => contract.id,
      "previous_status" => previous.status,
      "status" => contract.status,
      "event_sequence" => event.sequence,
      "transitioned_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "access_contract",
      aggregate_id: contract.id,
      aggregate_version: event.sequence,
      event_type: "subscription.#{name}",
      topic: "subscriptions.#{name}",
      message_key: contract.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "subscription.#{name}",
      resource_type: "access_contract",
      resource_id: contract.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp reject!(repo, scope, contract, request, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "access_contract",
      contract.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "subscription.transition_rejected",
      resource_type: "access_contract",
      resource_id: contract.id,
      metadata: %{
        "action" => request.action,
        "current_status" => contract.status,
        "reason" => Atom.to_string(reason),
        "operator_reason" => request.reason
      },
      occurred_at: now
    })

    {:denied, reason}
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "access_contract",
         response_body:
           %{
             "access_contract_id" => contract_id,
             "status" => status,
             "event_sequence" => sequence
           } = response
       })
       when is_binary(contract_id) and is_binary(status) and is_integer(sequence),
       do: {:accepted, response}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}),
    do: {:denied, Map.fetch!(@replay_reasons, reason)}

  defp replay(key), do: raise("invalid persisted contract lifecycle response: #{inspect(key)}")

  defp response_data(previous, contract, event, request, now) do
    %{
      "access_contract_id" => contract.id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => contract.status,
      "event_sequence" => event.sequence,
      "transitioned_at" => DateTime.to_iso8601(now)
    }
  end

  defp next_event_sequence(repo, scope, contract_id) do
    current =
      ContractEvent
      |> where(
        [event],
        event.polo_id == ^scope.polo_id and event.access_contract_id == ^contract_id
      )
      |> repo.aggregate(:max, :sequence)

    (current || 0) + 1
  end

  defp event_name("suspend"), do: "suspended"
  defp event_name("reactivate"), do: "reactivated"

  defp open_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp request_hash(scope, contract_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      contract_id,
      request.action,
      request.reason
    })
  end

  defp fetch_active_polo(repo, polo_id) do
    case repo.one(from(polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE")) do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp cast_contract_id(contract_id) do
    case Ecto.UUID.cast(contract_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :access_contract_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
