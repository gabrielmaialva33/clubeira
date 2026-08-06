defmodule Clubeira.Billing.RefundSettler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.Refund
  alias Clubeira.Billing.RefundPaymentGraph
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementLedgerEntry
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Tenancy.Scope

  @maximum_provider_clock_skew_seconds 300

  @spec settle_reserved(Scope.t(), Ecto.UUID.t(), Gateways.refunded_payment()) ::
          {:ok, Refund.t()} | {:error, atom() | Ecto.Changeset.t()}
  def settle_reserved(%Scope{} = scope, refund_id, provider_refund)
      when is_map(provider_refund) do
    Repo.transact_in_polo(scope, fn repo ->
      refund = lock_refund!(repo, scope, refund_id)

      cond do
        refund.status == "succeeded" and same_refund?(refund, provider_refund) ->
          {:ok, refund}

        refund.status not in ["requested", "processing"] ->
          {:error, :refund_unavailable}

        true ->
          settle_new(repo, scope, refund, provider_refund)
      end
    end)
  end

  @spec reconcile(
          Scope.t(),
          PaymentProvider.t(),
          MerchantAccount.t(),
          Gateways.refunded_payment()
        ) :: {:ok, Refund.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reconcile(
        %Scope{actor_user_id: nil} = scope,
        %PaymentProvider{} = provider,
        %MerchantAccount{} = account,
        provider_refund
      )
      when is_map(provider_refund) do
    Repo.transact_in_polo(scope, fn repo ->
      with {:ok, graph} <-
             RefundPaymentGraph.lock_by_provider(
               repo,
               scope,
               provider,
               account,
               provider_refund
             ) do
        reconcile_provider_refund(repo, scope, graph, provider_refund)
      end
    end)
  end

  def reconcile(%Scope{}, %PaymentProvider{}, %MerchantAccount{}, _provider_refund),
    do: {:error, :service_scope_required}

  defp reconcile_provider_refund(repo, scope, graph, provider_refund) do
    case lock_current_refund(repo, scope, graph.payment.id) do
      %Refund{status: "succeeded"} = refund ->
        if same_refund?(refund, provider_refund) do
          {:ok, refund}
        else
          {:error, :refund_reconciliation_mismatch}
        end

      %Refund{status: status} = refund when status in ["requested", "processing"] ->
        with :ok <- RefundPaymentGraph.refundable(graph) do
          settle_with_graph(repo, scope, refund, provider_refund, graph)
        end

      nil ->
        with :ok <- RefundPaymentGraph.refundable(graph),
             {:ok, refund} <- insert_provider_refund(repo, scope, graph.payment, provider_refund) do
          settle_with_graph(repo, scope, refund, provider_refund, graph)
        end
    end
  end

  defp settle_new(repo, scope, refund, provider_refund) do
    with {:ok, graph} <- RefundPaymentGraph.lock_by_payment(repo, scope, refund.payment_id),
         :ok <- RefundPaymentGraph.refundable(graph) do
      settle_with_graph(repo, scope, refund, provider_refund, graph)
    end
  end

  defp settle_with_graph(repo, scope, refund, provider_refund, graph) do
    now = transaction_time(repo)

    with :ok <- validate_provider_refund(scope, graph, refund, provider_refund, now),
         {:ok, subscription} <- lock_subscription(repo, scope, graph.order.id),
         {:ok, provider_event} <- insert_provider_event(repo, scope, graph, provider_refund, now) do
      succeeded = mark_succeeded!(repo, refund, provider_refund, now)
      mark_payment_and_order_refunded!(repo, graph.payment, graph.order, now)
      cancel_subscription!(repo, scope, subscription, succeeded, graph, now)
      mark_provider_event_processed!(repo, provider_event, now)
      record_refund!(repo, scope, succeeded, graph, subscription.contract, now)
      {:ok, succeeded}
    end
  end

  defp lock_current_refund(repo, scope, payment_id) do
    refunds =
      Refund
      |> where(
        [refund],
        refund.polo_id == ^scope.polo_id and refund.payment_id == ^payment_id and
          refund.status in ["requested", "processing", "succeeded"]
      )
      |> order_by([refund], asc: refund.inserted_at, asc: refund.id)
      |> lock("FOR UPDATE")
      |> repo.all()

    case refunds do
      [] -> nil
      [refund] -> refund
      _inconsistent -> raise "payment #{payment_id} has multiple live refunds"
    end
  end

  defp insert_provider_refund(repo, scope, payment, provider_refund) do
    now = transaction_time(repo)

    %Refund{
      id: uuid7(),
      polo_id: scope.polo_id,
      payment_id: payment.id,
      amount: provider_refund.amount,
      reason: "provider_initiated",
      status: "requested",
      requested_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:payment_id, name: :refunds_live_payment_uidx)
    |> repo.insert()
  end

  defp lock_refund!(repo, scope, refund_id) do
    Refund
    |> where([refund], refund.id == ^refund_id and refund.polo_id == ^scope.polo_id)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp validate_provider_refund(scope, graph, refund, provider_refund, now) do
    earliest = DateTime.add(graph.payment.captured_at, -@maximum_provider_clock_skew_seconds)
    latest = DateTime.add(now, @maximum_provider_clock_skew_seconds)

    cond do
      not matching_provider_refund?(scope, graph, refund, provider_refund) ->
        {:error, :refund_reconciliation_mismatch}

      not timestamp_between?(provider_refund.occurred_at, earliest, latest) ->
        {:error, :refund_timestamp_out_of_bounds}

      true ->
        :ok
    end
  end

  defp matching_provider_refund?(scope, graph, refund, provider_refund) do
    provider_refund.polo_id == scope.polo_id and
      provider_refund.order_id == graph.order.id and
      provider_refund.provider_reference == graph.intent.provider_reference and
      provider_refund.provider_payment_reference == graph.payment.provider_reference and
      provider_refund.currency == graph.payment.currency and
      Decimal.equal?(provider_refund.amount, graph.payment.amount) and
      Decimal.equal?(provider_refund.amount, refund.amount)
  end

  defp timestamp_between?(timestamp, earliest, latest) do
    not DateTime.before?(timestamp, earliest) and not DateTime.after?(timestamp, latest)
  end

  defp lock_subscription(repo, scope, order_id) do
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
      [%AccessContract{status: status} = contract]
      when status in ["active", "past_due", "suspended"] ->
        cycles = lock_cycles(repo, scope, contract.id)
        allocations = lock_allocations(repo, scope, contract.id)
        {:ok, %{contract: contract, cycles: cycles, allocations: allocations}}

      _missing_or_unsupported ->
        {:error, :subscription_not_refundable}
    end
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

  defp insert_provider_event(repo, scope, graph, provider_refund, now) do
    id = uuid7()
    external_event_id = "refund:" <> provider_refund.provider_refund_reference

    attributes = %{
      id: id,
      payment_provider_id: graph.provider.id,
      merchant_account_id: graph.account.id,
      polo_id: scope.polo_id,
      external_event_id: external_event_id,
      event_type: "payment.refunded",
      payload: provider_refund.payload,
      payload_sha256: Idempotency.fingerprint(provider_refund.payload),
      received_at: now
    }

    case repo.insert_all(PaymentProviderEvent, [attributes],
           on_conflict: :nothing,
           conflict_target: [:payment_provider_id, :merchant_account_id, :external_event_id],
           returning: [:id]
         ) do
      {1, [%{id: ^id}]} -> {:ok, repo.get!(PaymentProviderEvent, id)}
      {0, []} -> {:error, :provider_event_already_received}
    end
  end

  defp mark_succeeded!(repo, refund, provider_refund, now) do
    refund
    |> Ecto.Changeset.change(
      provider_reference: provider_refund.provider_refund_reference,
      status: "succeeded",
      completed_at: now,
      updated_at: now
    )
    |> Ecto.Changeset.unique_constraint(:provider_reference,
      name: :refunds_payment_provider_reference_uidx
    )
    |> Ecto.Changeset.unique_constraint(:payment_id, name: :refunds_succeeded_payment_uidx)
    |> repo.update!()
  end

  defp mark_payment_and_order_refunded!(repo, payment, order, now) do
    payment
    |> Ecto.Changeset.change(status: "refunded", refunded_at: now)
    |> repo.update!()

    order
    |> Ecto.Changeset.change(status: "refunded", updated_at: now)
    |> repo.update!()
  end

  defp cancel_subscription!(repo, scope, subscription, refund, graph, now) do
    Enum.each(subscription.allocations, &revoke_available_balance!(repo, scope, &1, refund, now))

    Enum.each(subscription.cycles, fn cycle ->
      if cycle.status in ["planned", "active"] do
        cycle
        |> Ecto.Changeset.change(status: "cancelled", closed_at: now)
        |> repo.update!()
      end
    end)

    contract =
      subscription.contract
      |> Ecto.Changeset.change(status: "cancelled", cancelled_at: now, updated_at: now)
      |> repo.update!()

    sequence = next_contract_event_sequence(repo, scope, contract.id)

    payload = %{
      "access_contract_id" => contract.id,
      "order_id" => graph.order.id,
      "payment_id" => graph.payment.id,
      "refund_id" => refund.id,
      "cancelled_at" => DateTime.to_iso8601(now)
    }

    %ContractEvent{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      sequence: sequence,
      event_type: "cancelled_by_refund",
      actor_user_id: refund.requested_by_user_id,
      payload: payload,
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "access_contract",
      aggregate_id: contract.id,
      aggregate_version: sequence,
      event_type: "subscription.cancelled",
      topic: "subscriptions.cancelled",
      message_key: contract.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })
  end

  defp revoke_available_balance!(_repo, _scope, %{available_units: 0}, _refund, _now), do: :ok

  defp revoke_available_balance!(repo, scope, allocation, refund, now) do
    %EntitlementLedgerEntry{
      polo_id: scope.polo_id,
      entitlement_allocation_id: allocation.id,
      entry_kind: "refund_revocation",
      delta_units: -allocation.available_units,
      idempotency_key: "refund:#{refund.id}:#{allocation.id}",
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()

    allocation
    |> Ecto.Changeset.change(available_units: 0, updated_at: now)
    |> repo.update!()
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

  defp record_refund!(repo, scope, refund, graph, contract, now) do
    payload = %{
      "refund_id" => refund.id,
      "payment_id" => graph.payment.id,
      "order_id" => graph.order.id,
      "access_contract_id" => contract.id,
      "currency" => graph.payment.currency,
      "amount" => Decimal.to_string(refund.amount),
      "completed_at" => DateTime.to_iso8601(refund.completed_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "refund",
      aggregate_id: refund.id,
      aggregate_version: 1,
      event_type: "refund.succeeded",
      topic: "billing.refunds.succeeded",
      message_key: refund.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "payment",
      aggregate_id: graph.payment.id,
      aggregate_version: 2,
      event_type: "payment.refunded",
      topic: "billing.payments.refunded",
      message_key: graph.payment.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "order",
      aggregate_id: graph.order.id,
      aggregate_version: 3,
      event_type: "order.refunded",
      topic: "billing.orders.refunded",
      message_key: graph.order.id,
      payload: %{
        "order_id" => graph.order.id,
        "payment_id" => graph.payment.id,
        "refund_id" => refund.id
      },
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "refund.succeeded",
      resource_type: "refund",
      resource_id: refund.id,
      metadata: Map.put(payload, "reason", refund.reason),
      occurred_at: now
    })
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp same_refund?(refund, provider_refund) do
    refund.provider_reference == provider_refund.provider_refund_reference and
      Decimal.equal?(refund.amount, provider_refund.amount)
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
