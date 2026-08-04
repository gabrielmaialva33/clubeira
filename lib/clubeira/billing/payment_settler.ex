defmodule Clubeira.Billing.PaymentSettler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Billing.SettledPayment
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.Provisioner
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "billing.settle_payment"
  @maximum_provider_clock_skew_seconds 300
  @replay_reasons %{
    "benefit_package_unavailable" => :benefit_package_unavailable,
    "entitlement_scope_empty" => :entitlement_scope_empty,
    "invalid_cycle_interval" => :invalid_cycle_interval,
    "merchant_account_unavailable" => :merchant_account_unavailable,
    "order_already_paid" => :order_already_paid,
    "order_not_found" => :order_not_found,
    "order_not_payable" => :order_not_payable,
    "order_update_failed" => :order_update_failed,
    "payment_amount_mismatch" => :payment_amount_mismatch,
    "payment_attempt_conflict" => :payment_attempt_conflict,
    "payment_reference_conflict" => :payment_reference_conflict,
    "payment_record_invalid" => :payment_record_invalid,
    "payment_timestamp_out_of_bounds" => :payment_timestamp_out_of_bounds,
    "polo_policy_unavailable" => :polo_policy_unavailable,
    "provider_event_already_received" => :provider_event_already_received,
    "subscription_configuration_invalid" => :subscription_configuration_invalid,
    "unsupported_activation_policy" => :unsupported_activation_policy,
    "unsupported_cycle_policy" => :unsupported_cycle_policy,
    "unsupported_order_shape" => :unsupported_order_shape,
    "unsupported_subject_policy" => :unsupported_subject_policy
  }

  @spec settle(Scope.t(), map()) ::
          {:ok, AccessContract.t()} | {:error, atom() | Ecto.Changeset.t()}
  def settle(%Scope{actor_user_id: actor_user_id}, _attributes) when not is_nil(actor_user_id) do
    {:error, :service_scope_required}
  end

  def settle(%Scope{} = scope, attributes) do
    with {:ok, request} <- SettledPayment.new(attributes) do
      idempotency_key = idempotency_key(request)
      request_hash = request_hash(scope, request)

      scope
      |> transact_settlement(request, idempotency_key, request_hash)
      |> unwrap_transaction()
    end
  end

  def settle(_scope, _attributes), do: {:error, :service_scope_required}

  defp transact_settlement(scope, request, idempotency_key, request_hash) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      outcome =
        case Idempotency.reserve(
               repo,
               scope,
               @idempotency_scope,
               idempotency_key,
               request_hash,
               now
             ) do
          {:new, idempotency_id} -> settle_new(repo, scope, request, idempotency_id, now)
          {:replay, key} -> replay(repo, key)
          {:error, reason} -> {:denied, reason}
        end

      {:ok, outcome}
    end)
  end

  defp settle_new(repo, scope, request, idempotency_id, now) do
    with :ok <- lock_merchant_account_link(repo, scope, request),
         {:ok, order} <- lock_order(repo, scope, request.order_id),
         {:ok, provider_event} <- insert_provider_event(repo, scope, request, now) do
      settle_received_event(repo, scope, request, idempotency_id, order, provider_event, now)
    else
      {:error, reason} -> reject!(repo, idempotency_id, reason, nil, now)
    end
  end

  defp settle_received_event(repo, scope, request, idempotency_id, order, provider_event, now) do
    with :ok <- ensure_merchant_account_available(repo, scope, request, now),
         :ok <- ensure_order_payable(order),
         :ok <- validate_payment(order, request, now),
         {:ok, order_item} <- lock_single_order_item(repo, scope, order),
         {:ok, provisioning_plan} <-
           Provisioner.prepare(repo, scope, order_item, now),
         {:ok, intent, payment} <- insert_capture(repo, scope, order, request, now),
         {:ok, paid_order} <- mark_order_paid(repo, order, now) do
      record_payment!(repo, scope, paid_order, intent, payment, now)

      contract =
        Provisioner.materialize!(
          repo,
          scope,
          paid_order,
          order_item,
          payment,
          provisioning_plan,
          now
        )

      mark_provider_event_processed!(repo, provider_event, now)

      Idempotency.complete!(
        repo,
        idempotency_id,
        "access_contract",
        contract.id,
        %{"access_contract_id" => contract.id},
        now
      )

      {:accepted, contract}
    else
      {:error, reason} ->
        reject!(repo, idempotency_id, reason, provider_event, now)
    end
  end

  defp lock_merchant_account_link(repo, scope, request) do
    query =
      from assignment in PoloMerchantAccount,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.merchant_account_id == ^request.merchant_account_id and
            assignment.payment_provider_id == ^request.payment_provider_id,
        lock: "FOR SHARE",
        select: assignment.merchant_account_id

    if repo.one(query), do: :ok, else: {:error, :merchant_account_unavailable}
  end

  defp ensure_merchant_account_available(repo, scope, request, now) do
    query =
      from assignment in PoloMerchantAccount,
        join: account in MerchantAccount,
        on: account.id == assignment.merchant_account_id,
        join: provider in PaymentProvider,
        on: provider.id == account.payment_provider_id,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.merchant_account_id == ^request.merchant_account_id and
            assignment.payment_provider_id == ^request.payment_provider_id and
            account.id == ^request.merchant_account_id and
            account.payment_provider_id == ^request.payment_provider_id,
        where:
          account.kind == "consumer" and account.status == "active" and
            provider.status == "active",
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            assignment.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: account.id

    if repo.one(query), do: :ok, else: {:error, :merchant_account_unavailable}
  end

  defp insert_provider_event(repo, scope, request, now) do
    id = uuid7()

    attributes = %{
      id: id,
      payment_provider_id: request.payment_provider_id,
      merchant_account_id: request.merchant_account_id,
      polo_id: scope.polo_id,
      external_event_id: request.external_event_id,
      event_type: "payment.captured",
      payload: request.payload,
      payload_sha256: Idempotency.fingerprint(request.payload),
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

  defp lock_order(repo, scope, order_id) do
    query =
      from order in Order,
        where: order.id == ^order_id and order.polo_id == ^scope.polo_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Order{} = order -> {:ok, order}
      nil -> {:error, :order_not_found}
    end
  end

  defp ensure_order_payable(%Order{status: status, placed_at: %DateTime{}})
       when status in ["pending", "awaiting_payment"],
       do: :ok

  defp ensure_order_payable(%Order{status: "paid"}), do: {:error, :order_already_paid}
  defp ensure_order_payable(%Order{}), do: {:error, :order_not_payable}

  defp validate_payment(order, request, now) do
    cond do
      order.currency != request.currency or
          not Decimal.equal?(order.total_amount, request.amount) ->
        {:error, :payment_amount_mismatch}

      timestamp_out_of_bounds?(order, request, now) ->
        {:error, :payment_timestamp_out_of_bounds}

      true ->
        :ok
    end
  end

  defp timestamp_out_of_bounds?(order, request, now) do
    earliest = DateTime.add(order.placed_at, -@maximum_provider_clock_skew_seconds, :second)
    latest = DateTime.add(now, @maximum_provider_clock_skew_seconds, :second)

    DateTime.before?(request.occurred_at, earliest) or
      DateTime.after?(request.occurred_at, latest)
  end

  defp lock_single_order_item(repo, scope, order) do
    items =
      OrderItem
      |> where([item], item.polo_id == ^scope.polo_id and item.order_id == ^order.id)
      |> order_by([item], asc: item.id)
      |> lock("FOR SHARE")
      |> repo.all()

    case items do
      [%OrderItem{} = item] ->
        if Decimal.equal?(item.total_amount, order.total_amount) do
          {:ok, item}
        else
          {:error, :subscription_configuration_invalid}
        end

      _items ->
        {:error, :unsupported_order_shape}
    end
  end

  defp insert_capture(repo, scope, order, request, now) do
    repo.query!("SAVEPOINT clubeira_billing_capture")

    case do_insert_capture(repo, scope, order, request, now) do
      {:ok, _intent, _payment} = accepted ->
        repo.query!("RELEASE SAVEPOINT clubeira_billing_capture")
        accepted

      {:error, _reason} = rejected ->
        repo.query!("ROLLBACK TO SAVEPOINT clubeira_billing_capture")
        repo.query!("RELEASE SAVEPOINT clubeira_billing_capture")
        rejected
    end
  end

  defp do_insert_capture(repo, scope, order, request, now) do
    key = idempotency_key(request)

    intent_changeset =
      %PaymentIntent{
        polo_id: scope.polo_id,
        order_id: order.id,
        merchant_account_id: request.merchant_account_id,
        idempotency_key: key,
        provider_reference: request.provider_reference,
        currency: request.currency,
        amount: request.amount,
        status: "succeeded",
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:provider_reference,
        name: :payment_intents_provider_reference_uidx
      )
      |> Ecto.Changeset.unique_constraint(:order_id,
        name: :payment_intents_live_order_uidx
      )
      |> Ecto.Changeset.unique_constraint(:idempotency_key,
        name: :payment_intents_order_idempotency_uidx
      )

    with {:ok, intent} <- repo.insert(intent_changeset, mode: :savepoint),
         {:ok, payment} <- insert_payment(repo, scope, intent, request, now) do
      {:ok, intent, payment}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, capture_error_reason(changeset)}
    end
  end

  defp insert_payment(repo, scope, intent, request, now) do
    %Payment{
      polo_id: scope.polo_id,
      payment_intent_id: intent.id,
      merchant_account_id: request.merchant_account_id,
      provider_reference: request.provider_reference,
      currency: request.currency,
      amount: request.amount,
      status: "captured",
      captured_at: request.occurred_at,
      inserted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:provider_reference,
      name: :payments_provider_reference_uidx
    )
    |> repo.insert(mode: :savepoint)
  end

  defp capture_error_reason(changeset) do
    cond do
      constraint_error?(changeset, [
        "payment_intents_provider_reference_uidx",
        "payments_provider_reference_uidx"
      ]) ->
        :payment_reference_conflict

      constraint_error?(changeset, [
        "payment_intents_live_order_uidx",
        "payment_intents_order_idempotency_uidx"
      ]) ->
        :payment_attempt_conflict

      true ->
        :payment_record_invalid
    end
  end

  defp constraint_error?(changeset, names) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      to_string(options[:constraint_name]) in names
    end)
  end

  defp mark_order_paid(repo, order, now) do
    case repo.update(Ecto.Changeset.change(order, status: "paid", updated_at: now)) do
      {:ok, %Order{} = paid_order} -> {:ok, paid_order}
      {:error, %Ecto.Changeset{}} -> {:error, :order_update_failed}
    end
  end

  defp record_payment!(repo, scope, order, intent, payment, now) do
    payment_payload = %{
      "payment_id" => payment.id,
      "payment_intent_id" => intent.id,
      "order_id" => order.id,
      "currency" => payment.currency,
      "amount" => Decimal.to_string(payment.amount),
      "captured_at" => DateTime.to_iso8601(payment.captured_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "payment",
      aggregate_id: payment.id,
      aggregate_version: 1,
      event_type: "payment.captured",
      topic: "billing.payments.captured",
      message_key: payment.id,
      payload: payment_payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "order",
      aggregate_id: order.id,
      aggregate_version: 2,
      event_type: "order.paid",
      topic: "billing.orders.paid",
      message_key: order.id,
      payload: %{"order_id" => order.id, "payment_id" => payment.id},
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "payment.captured",
      resource_type: "payment",
      resource_id: payment.id,
      metadata: payment_payload,
      occurred_at: now
    })
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp reject!(repo, idempotency_id, reason, event, now) do
    if event do
      event
      |> Ecto.Changeset.change(processed_at: now, processing_error: Atom.to_string(reason))
      |> repo.update!()
    end

    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      if(event, do: "payment_provider_event"),
      if(event, do: event.id),
      now
    )

    {:denied, reason}
  end

  defp replay(repo, %Key{
         status: "completed",
         resource_type: "access_contract",
         resource_id: id
       }) do
    case repo.get(AccessContract, id) do
      %AccessContract{} = contract -> {:accepted, contract}
      nil -> raise "completed settlement idempotency key points to missing resource #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted settlement idempotency response: #{inspect(key)}"
  end

  defp idempotency_key(request) do
    digest =
      Idempotency.fingerprint({
        request.payment_provider_id,
        request.merchant_account_id,
        request.external_event_id
      })

    "provider-event:" <> Base.encode16(digest, case: :lower)
  end

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      request.order_id,
      request.payment_provider_id,
      request.merchant_account_id,
      request.external_event_id,
      request.provider_reference,
      request.amount |> Decimal.normalize() |> Decimal.to_string(:normal),
      request.currency,
      request.occurred_at,
      request.payload
    })
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, contract}}), do: {:ok, contract}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
