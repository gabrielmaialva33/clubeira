defmodule Clubeira.Billing.PaymentAccessLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.Chargeback
  alias Clubeira.Billing.Refund
  alias Clubeira.Events
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Subscriptions.ContractSuspension
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementLedgerEntry
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Tenancy.Scope

  @type graph :: %{
          contract: AccessContract.t(),
          cycles: [struct()],
          allocations: [struct()]
        }

  @spec lock(module(), Scope.t(), Ecto.UUID.t()) ::
          {:ok, graph()} | {:error, :subscription_not_found}
  def lock(repo, scope, order_id) do
    contracts =
      OrderItem
      |> join(:inner, [item], contract in AccessContract,
        on: contract.order_item_id == item.id and contract.polo_id == item.polo_id
      )
      |> where([item], item.order_id == ^order_id and item.polo_id == ^scope.polo_id)
      |> select([_item, contract], contract)
      |> lock("FOR UPDATE")
      |> repo.all()

    case contracts do
      [%AccessContract{} = contract] ->
        {:ok,
         %{
           contract: contract,
           cycles: lock_cycles(repo, scope, contract.id),
           allocations: lock_allocations(repo, scope, contract.id)
         }}

      [] ->
        {:error, :subscription_not_found}

      _inconsistent ->
        raise "order #{order_id} has multiple access contracts"
    end
  end

  @spec refundable(graph()) :: :ok | {:error, :subscription_not_refundable}
  def refundable(%{contract: %AccessContract{status: status}})
      when status in ["active", "past_due", "suspended"],
      do: :ok

  def refundable(_graph), do: {:error, :subscription_not_refundable}

  @spec cancel_for_refund!(module(), Scope.t(), graph(), Refund.t(), map(), DateTime.t()) ::
          AccessContract.t()
  def cancel_for_refund!(repo, scope, graph, refund, payment_graph, now) do
    cancel!(repo, scope, graph, %{
      actor_user_id: refund.requested_by_user_id,
      ledger_entry_kind: "refund_revocation",
      ledger_key_prefix: "refund:#{refund.id}",
      contract_event_type: "cancelled_by_refund",
      cause: "refund",
      cause_id: refund.id,
      payment_id: payment_graph.payment.id,
      order_id: payment_graph.order.id,
      now: now
    })
  end

  @spec apply_chargeback!(
          module(),
          Scope.t(),
          graph(),
          Chargeback.t(),
          String.t() | nil,
          map(),
          DateTime.t()
        ) :: {:ok, AccessContract.t()} | {:error, :subscription_not_chargebackable}
  def apply_chargeback!(repo, scope, graph, chargeback, previous_status, payment_graph, now) do
    cond do
      chargeback.status in ["open", "under_review"] and
          previous_status not in ["open", "under_review"] ->
        suspend_for_chargeback!(repo, scope, graph, chargeback, payment_graph, now)

      chargeback.status == "won" and previous_status in ["open", "under_review"] ->
        restore_after_chargeback!(repo, scope, graph, chargeback, payment_graph, now)

      chargeback.status == "lost" and previous_status != "lost" ->
        {:ok,
         cancel!(repo, scope, graph, %{
           actor_user_id: nil,
           ledger_entry_kind: "chargeback_revocation",
           ledger_key_prefix: "chargeback:#{chargeback.id}",
           contract_event_type: "cancelled_by_chargeback",
           cause: "chargeback",
           cause_id: chargeback.id,
           payment_id: payment_graph.payment.id,
           order_id: payment_graph.order.id,
           now: now
         })}

      chargeback.status in ["open", "under_review", "won", "lost"] ->
        {:ok, graph.contract}

      true ->
        {:error, :subscription_not_chargebackable}
    end
  end

  defp suspend_for_chargeback!(repo, scope, graph, chargeback, payment_graph, now) do
    case graph.contract do
      %AccessContract{status: status} = contract when status in ["active", "past_due"] ->
        updated = update_contract!(repo, contract, status: "suspended", updated_at: now)

        event =
          insert_contract_event!(repo, scope, updated, %{
            actor_user_id: nil,
            event_type: "suspended_by_chargeback",
            payload: %{
              "chargeback_id" => chargeback.id,
              "order_id" => payment_graph.order.id,
              "payment_id" => payment_graph.payment.id,
              "previous_status" => status,
              "status" => "suspended"
            },
            now: now
          })

        %ContractSuspension{
          polo_id: scope.polo_id,
          access_contract_id: contract.id,
          source_contract_event_id: event.id,
          reason: "chargeback:#{chargeback.id}",
          suspended_during: open_range(now),
          inserted_at: now
        }
        |> repo.insert!()

        emit_contract_transition!(repo, scope, updated, event, "suspended", now)
        {:ok, updated}

      %AccessContract{status: "suspended"} = contract ->
        {:ok, contract}

      _unsupported ->
        {:error, :subscription_not_chargebackable}
    end
  end

  defp restore_after_chargeback!(repo, scope, graph, chargeback, payment_graph, now) do
    case lock_chargeback_suspension(repo, scope, graph.contract.id, chargeback.id) do
      {%ContractSuspension{} = suspension, %ContractEvent{} = source_event} ->
        previous_status = source_event.payload["previous_status"]

        if previous_status in ["active", "past_due"] do
          close_suspension!(repo, suspension, now)

          updated =
            update_contract!(repo, graph.contract, status: previous_status, updated_at: now)

          event =
            insert_contract_event!(repo, scope, updated, %{
              actor_user_id: nil,
              event_type: "reactivated_after_chargeback",
              payload: %{
                "chargeback_id" => chargeback.id,
                "order_id" => payment_graph.order.id,
                "payment_id" => payment_graph.payment.id,
                "previous_status" => "suspended",
                "status" => previous_status
              },
              now: now
            })

          emit_contract_transition!(repo, scope, updated, event, "reactivated", now)
          {:ok, updated}
        else
          {:error, :subscription_not_chargebackable}
        end

      nil ->
        {:ok, graph.contract}
    end
  end

  defp cancel!(repo, scope, graph, attributes) do
    if graph.contract.status == "cancelled" do
      graph.contract
    else
      cancel_graph!(repo, scope, graph, attributes)
    end
  end

  defp cancel_graph!(repo, scope, graph, attributes) do
    revoke_allocations!(repo, scope, graph.allocations, attributes)
    cancel_cycles!(repo, graph.cycles, attributes.now)
    close_open_suspension!(repo, scope, graph.contract.id, attributes.now)

    contract =
      update_contract!(repo, graph.contract,
        status: "cancelled",
        cancelled_at: attributes.now,
        updated_at: attributes.now
      )

    event = insert_cancellation_event!(repo, scope, contract, attributes)
    emit_contract_transition!(repo, scope, contract, event, "cancelled", attributes.now)
    contract
  end

  defp revoke_allocations!(repo, scope, allocations, attributes) do
    Enum.each(allocations, &revoke_available_balance!(repo, scope, &1, attributes))
  end

  defp cancel_cycles!(repo, cycles, now) do
    cycles
    |> Enum.filter(&(&1.status in ["planned", "active"]))
    |> Enum.each(fn cycle ->
      cycle
      |> Ecto.Changeset.change(status: "cancelled", closed_at: now)
      |> repo.update!()
    end)
  end

  defp insert_cancellation_event!(repo, scope, contract, attributes) do
    insert_contract_event!(repo, scope, contract, %{
      actor_user_id: attributes.actor_user_id,
      event_type: attributes.contract_event_type,
      payload: %{
        "access_contract_id" => contract.id,
        "cause" => attributes.cause,
        "cause_id" => attributes.cause_id,
        "order_id" => attributes.order_id,
        "payment_id" => attributes.payment_id,
        "cancelled_at" => DateTime.to_iso8601(attributes.now)
      },
      now: attributes.now
    })
  end

  defp lock_cycles(repo, scope, contract_id) do
    BenefitCycle
    |> where(
      [cycle],
      cycle.polo_id == ^scope.polo_id and cycle.access_contract_id == ^contract_id
    )
    |> order_by([cycle], asc: cycle.sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp lock_allocations(repo, scope, contract_id) do
    EntitlementAllocation
    |> join(:inner, [allocation], subject in CycleEntitlementSubject,
      on:
        subject.id == allocation.cycle_entitlement_subject_id and
          subject.polo_id == allocation.polo_id
    )
    |> where(
      [allocation, subject],
      allocation.polo_id == ^scope.polo_id and subject.access_contract_id == ^contract_id
    )
    |> order_by([allocation], asc: allocation.id)
    |> lock("FOR UPDATE")
    |> select([allocation], allocation)
    |> repo.all()
  end

  defp lock_chargeback_suspension(repo, scope, contract_id, chargeback_id) do
    query =
      from suspension in ContractSuspension,
        join: event in ContractEvent,
        on:
          event.id == suspension.source_contract_event_id and
            event.polo_id == suspension.polo_id and
            event.access_contract_id == suspension.access_contract_id,
        where:
          suspension.polo_id == ^scope.polo_id and
            suspension.access_contract_id == ^contract_id and
            suspension.reason == ^"chargeback:#{chargeback_id}" and
            fragment("upper_inf(?)", suspension.suspended_during),
        lock: "FOR UPDATE",
        select: {suspension, event}

    repo.one(query)
  end

  defp close_open_suspension!(repo, scope, contract_id, now) do
    ContractSuspension
    |> where(
      [suspension],
      suspension.polo_id == ^scope.polo_id and
        suspension.access_contract_id == ^contract_id and
        fragment("upper_inf(?)", suspension.suspended_during)
    )
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.each(&close_suspension!(repo, &1, now))
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

  defp revoke_available_balance!(_repo, _scope, %{available_units: 0}, _attributes), do: :ok

  defp revoke_available_balance!(repo, scope, allocation, attributes) do
    %EntitlementLedgerEntry{
      polo_id: scope.polo_id,
      entitlement_allocation_id: allocation.id,
      entry_kind: attributes.ledger_entry_kind,
      delta_units: -allocation.available_units,
      idempotency_key: "#{attributes.ledger_key_prefix}:#{allocation.id}",
      occurred_at: attributes.now,
      inserted_at: attributes.now
    }
    |> repo.insert!()

    allocation
    |> Ecto.Changeset.change(available_units: 0, updated_at: attributes.now)
    |> repo.update!()
  end

  defp update_contract!(repo, contract, attributes) do
    contract
    |> Ecto.Changeset.change(attributes)
    |> repo.update!()
  end

  defp insert_contract_event!(repo, scope, contract, attributes) do
    %ContractEvent{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      sequence: next_contract_event_sequence(repo, scope, contract.id),
      event_type: attributes.event_type,
      actor_user_id: attributes.actor_user_id,
      payload: attributes.payload,
      occurred_at: attributes.now,
      inserted_at: attributes.now
    }
    |> repo.insert!()
  end

  defp emit_contract_transition!(repo, scope, contract, event, transition, now) do
    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "access_contract",
      aggregate_id: contract.id,
      aggregate_version: event.sequence,
      event_type: "subscription.#{transition}",
      topic: "subscriptions.#{transition}",
      message_key: contract.id,
      payload: event.payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })
  end

  defp next_contract_event_sequence(repo, scope, contract_id) do
    current =
      ContractEvent
      |> where(
        [event],
        event.polo_id == ^scope.polo_id and event.access_contract_id == ^contract_id
      )
      |> repo.aggregate(:max, :sequence)

    (current || 0) + 1
  end

  defp open_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}
end
