defmodule Clubeira.Billing.RecurringInvoiceSettler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.Billing.ConsumerInvoice
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Billing.RecurringInvoice
  alias Clubeira.Events
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Subscriptions.Provisioner
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "billing.reconcile_recurring_invoice"
  @replay_reasons %{
    "automatic_renewal_not_enabled" => :automatic_renewal_not_enabled,
    "billing_agreement_not_found" => :billing_agreement_not_found,
    "billing_agreement_unavailable" => :billing_agreement_unavailable,
    "merchant_account_unavailable" => :merchant_account_unavailable,
    "recurring_invoice_amount_mismatch" => :recurring_invoice_amount_mismatch,
    "recurring_invoice_reference_conflict" => :recurring_invoice_reference_conflict,
    "subscription_configuration_invalid" => :subscription_configuration_invalid
  }

  @type result :: %{invoice: ConsumerInvoice.t(), contract: AccessContract.t()}

  @spec reconcile(
          Scope.t(),
          PaymentProvider.t(),
          MerchantAccount.t(),
          map()
        ) :: {:ok, result()} | {:error, term()}
  def reconcile(
        %Scope{actor_user_id: nil} = scope,
        %PaymentProvider{} = provider,
        %MerchantAccount{} = account,
        attributes
      )
      when is_map(attributes) do
    with {:ok, request} <- RecurringInvoice.new(attributes) do
      scope
      |> transact_reconciliation(provider, account, request)
      |> unwrap_transaction()
    end
  end

  def reconcile(_scope, _provider, _account, _attributes), do: {:error, :service_scope_required}

  defp transact_reconciliation(scope, provider, account, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      outcome =
        case Idempotency.reserve(
               repo,
               scope,
               @idempotency_scope,
               idempotency_key(request),
               request_hash(scope, provider, account, request),
               now
             ) do
          {:new, key_id} -> reconcile_new(repo, scope, provider, account, request, key_id, now)
          {:replay, key} -> replay(repo, key)
          {:error, reason} -> {:denied, reason}
        end

      {:ok, outcome}
    end)
  end

  defp reconcile_new(repo, scope, provider, account, request, key_id, now) do
    with {:ok, provider, account} <- lock_provider_account(repo, scope, provider, account, now),
         {:ok, agreement} <- lock_agreement(repo, scope, account, request),
         {:ok, order, order_item, offering} <- lock_source_graph(repo, scope, agreement),
         :ok <- validate_graph(agreement, order, order_item, offering, request),
         {:ok, provider_event} <-
           insert_provider_event(repo, scope, provider, account, request, now) do
      %{
        repo: repo,
        scope: scope,
        account: account,
        agreement: agreement,
        order: order,
        order_item: order_item,
        request: request,
        event: provider_event,
        key_id: key_id,
        now: now
      }
      |> settle_event()
    else
      {:error, reason} -> reject!(repo, key_id, reason, nil, now)
    end
  end

  defp settle_event(context) do
    case lock_contract(context.repo, context.scope, context.agreement.id) do
      nil ->
        settle_initial(context)

      contract ->
        context
        |> Map.put(:contract, contract)
        |> settle_renewal()
    end
  end

  defp settle_initial(context) do
    with :ok <- initial_order_payable(context.order),
         {:ok, plan} <-
           Provisioner.prepare(context.repo, context.scope, context.order_item, context.now) do
      {intent, payment} =
        insert_capture!(
          context.repo,
          context.scope,
          context.account,
          context.order,
          context.request,
          context.now
        )

      paid_order = mark_order_paid!(context.repo, context.order, context.now)

      record_capture!(
        context.repo,
        context.scope,
        paid_order,
        intent,
        payment,
        context.now,
        false
      )

      contract =
        Provisioner.materialize!(
          context.repo,
          context.scope,
          paid_order,
          context.order_item,
          payment,
          plan,
          context.now
        )
        |> Ecto.Changeset.change(
          billing_agreement_id: context.agreement.id,
          updated_at: context.now
        )
        |> context.repo.update!()

      context
      |> Map.merge(%{
        contract: contract,
        order: paid_order,
        billing_period: plan.benefits_during
      })
      |> finish_settlement!()
    else
      {:error, reason} ->
        reject!(context.repo, context.key_id, reason, context.event, context.now)
    end
  end

  defp settle_renewal(context) do
    with :ok <- renewable_contract(context.contract),
         {:ok, starts_at} <-
           renewal_starts_at(context.repo, context.scope, context.contract),
         {:ok, plan} <-
           Provisioner.prepare(context.repo, context.scope, context.order_item, starts_at) do
      {order, order_item} =
        insert_renewal_order!(
          context.repo,
          context.scope,
          context.agreement,
          context.order_item,
          context.request,
          context.now
        )

      {intent, payment} =
        insert_capture!(
          context.repo,
          context.scope,
          context.account,
          order,
          context.request,
          context.now
        )

      record_capture!(
        context.repo,
        context.scope,
        order,
        intent,
        payment,
        context.now,
        true
      )

      renewed =
        Provisioner.materialize_renewal!(
          context.repo,
          context.scope,
          context.contract,
          plan,
          context.now
        )

      context
      |> Map.merge(%{
        contract: renewed.contract,
        order: order,
        billing_period: renewed.cycle.benefits_during
      })
      |> finish_settlement!()
      |> tap(fn _result -> ensure_order_item_identity!(order_item, context.order_item) end)
    else
      {:error, reason} ->
        reject!(context.repo, context.key_id, reason, context.event, context.now)
    end
  end

  defp finish_settlement!(context) do
    invoice =
      insert_invoice!(
        context.repo,
        context.scope,
        context.account,
        context.agreement,
        context.order,
        context.billing_period,
        context.request,
        context.now
      )

    updated_agreement =
      activate_agreement!(
        context.repo,
        context.agreement,
        context.billing_period,
        context.now
      )

    mark_provider_event_processed!(context.repo, context.event, context.now)

    record_invoice!(
      context.repo,
      context.scope,
      updated_agreement,
      invoice,
      context.contract,
      context.now
    )

    Idempotency.complete!(
      context.repo,
      context.key_id,
      "consumer_invoice",
      invoice.id,
      %{
        "consumer_invoice_id" => invoice.id,
        "access_contract_id" => context.contract.id
      },
      context.now
    )

    {:accepted, %{invoice: invoice, contract: context.contract}}
  end

  defp lock_provider_account(repo, scope, supplied_provider, supplied_account, now) do
    query =
      from assignment in PoloMerchantAccount,
        join: account in MerchantAccount,
        on: account.id == assignment.merchant_account_id,
        join: provider in PaymentProvider,
        on: provider.id == assignment.payment_provider_id,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.merchant_account_id == ^supplied_account.id and
            assignment.payment_provider_id == ^supplied_provider.id,
        where:
          account.id == ^supplied_account.id and
            account.payment_provider_id == ^supplied_provider.id and account.kind == "consumer" and
            account.status == "active" and provider.status == "active",
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            assignment.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: {provider, account}

    case repo.one(query) do
      {%PaymentProvider{} = provider, %MerchantAccount{} = account} ->
        {:ok, provider, account}

      nil ->
        {:error, :merchant_account_unavailable}
    end
  end

  defp lock_agreement(repo, scope, account, request) do
    agreement =
      BillingAgreement
      |> where(
        [agreement],
        agreement.polo_id == ^scope.polo_id and
          agreement.merchant_account_id == ^account.id and
          agreement.provider_reference == ^request.billing_agreement_reference
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    if agreement, do: {:ok, agreement}, else: {:error, :billing_agreement_not_found}
  end

  defp lock_source_graph(repo, scope, agreement) do
    query =
      from item in OrderItem,
        join: order in Order,
        on: order.id == item.order_id and order.polo_id == item.polo_id,
        join: offering in ProductOfferingVersion,
        on: offering.id == item.product_offering_version_id and offering.polo_id == item.polo_id,
        where:
          item.id == ^agreement.order_item_id and item.polo_id == ^scope.polo_id and
            item.product_offering_version_id == ^agreement.product_offering_version_id and
            order.purchaser_user_id == ^agreement.user_id,
        lock: "FOR UPDATE",
        select: {order, item, offering}

    case repo.one(query) do
      {%Order{} = order, %OrderItem{} = item, %ProductOfferingVersion{} = offering} ->
        {:ok, order, item, offering}

      nil ->
        {:error, :subscription_configuration_invalid}
    end
  end

  defp validate_graph(agreement, order, item, offering, request) do
    cond do
      agreement.status not in ["pending", "active", "past_due"] ->
        {:error, :billing_agreement_unavailable}

      offering.renewal_policy != "automatic" ->
        {:error, :automatic_renewal_not_enabled}

      request.currency != order.currency or
          not Decimal.equal?(request.amount, item.total_amount) ->
        {:error, :recurring_invoice_amount_mismatch}

      request.polo_id != order.polo_id or request.order_id != order.id ->
        {:error, :billing_agreement_not_found}

      true ->
        :ok
    end
  end

  defp insert_provider_event(repo, scope, provider, account, request, now) do
    id = uuid7()

    attributes = %{
      id: id,
      payment_provider_id: provider.id,
      merchant_account_id: account.id,
      polo_id: scope.polo_id,
      external_event_id: request.external_event_id,
      event_type: "subscription_authorized_payment.captured",
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
      {0, []} -> {:error, :recurring_invoice_reference_conflict}
    end
  end

  defp lock_contract(repo, scope, agreement_id) do
    AccessContract
    |> where(
      [contract],
      contract.polo_id == ^scope.polo_id and contract.billing_agreement_id == ^agreement_id
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp initial_order_payable(%Order{status: status})
       when status in ["pending", "awaiting_payment"],
       do: :ok

  defp initial_order_payable(_order), do: {:error, :billing_agreement_unavailable}

  defp renewable_contract(%AccessContract{status: "active"}), do: :ok
  defp renewable_contract(_contract), do: {:error, :billing_agreement_unavailable}

  defp renewal_starts_at(repo, scope, contract) do
    case repo.one(
           from cycle in BenefitCycle,
             where: cycle.polo_id == ^scope.polo_id and cycle.access_contract_id == ^contract.id,
             order_by: [desc: cycle.sequence],
             limit: 1,
             lock: "FOR UPDATE"
         ) do
      %BenefitCycle{
        status: "active",
        benefits_during: %Postgrex.Range{upper: %DateTime{} = upper}
      } ->
        {:ok, upper}

      _missing_or_invalid ->
        {:error, :subscription_configuration_invalid}
    end
  end

  defp insert_capture!(repo, scope, account, order, request, now) do
    intent =
      %PaymentIntent{
        polo_id: scope.polo_id,
        order_id: order.id,
        merchant_account_id: account.id,
        idempotency_key: compact_key("recurring", request.provider_invoice_reference),
        provider_reference: request.provider_invoice_reference,
        currency: request.currency,
        amount: request.amount,
        status: "succeeded",
        next_action: %{},
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    payment =
      %Payment{
        polo_id: scope.polo_id,
        payment_intent_id: intent.id,
        merchant_account_id: account.id,
        provider_reference: request.provider_payment_reference,
        currency: request.currency,
        amount: request.amount,
        status: "captured",
        captured_at: request.occurred_at,
        inserted_at: now
      }
      |> repo.insert!()

    {intent, payment}
  end

  defp mark_order_paid!(repo, order, now) do
    order
    |> Ecto.Changeset.change(status: "paid", updated_at: now)
    |> repo.update!()
  end

  defp insert_renewal_order!(repo, scope, agreement, source_item, request, now) do
    id = uuid7()

    order =
      %Order{
        id: id,
        polo_id: scope.polo_id,
        purchaser_user_id: agreement.user_id,
        order_number: order_number(id),
        idempotency_key: compact_key("renewal", request.provider_invoice_reference),
        currency: request.currency,
        subtotal_amount: request.amount,
        discount_amount: Decimal.new(0),
        total_amount: request.amount,
        status: "paid",
        placed_at: now,
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    item =
      %OrderItem{
        polo_id: scope.polo_id,
        order_id: order.id,
        product_offering_version_id: source_item.product_offering_version_id,
        offering_price_id: source_item.offering_price_id,
        quantity: 1,
        unit_amount: request.amount,
        total_amount: request.amount,
        inserted_at: now
      }
      |> repo.insert!()

    {order, item}
  end

  defp insert_invoice!(repo, scope, account, agreement, order, billing_period, request, now) do
    id = uuid7()

    %ConsumerInvoice{
      id: id,
      polo_id: scope.polo_id,
      billing_agreement_id: agreement.id,
      order_id: order.id,
      merchant_account_id: account.id,
      provider_reference: request.provider_invoice_reference,
      invoice_number: invoice_number(id),
      billing_period: billing_period,
      currency: request.currency,
      subtotal_amount: request.amount,
      discount_amount: Decimal.new(0),
      total_amount: request.amount,
      status: "paid",
      issued_at: request.occurred_at,
      due_at: request.occurred_at,
      paid_at: request.occurred_at,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp activate_agreement!(repo, agreement, billing_period, now) do
    agreement
    |> Ecto.Changeset.change(
      status: "active",
      current_period: billing_period,
      next_charge_at: billing_period.upper,
      next_action: %{},
      updated_at: now
    )
    |> repo.update!()
  end

  defp record_capture!(repo, scope, order, intent, payment, now, renewal?) do
    payment_payload = %{
      "payment_id" => payment.id,
      "payment_intent_id" => intent.id,
      "order_id" => order.id,
      "currency" => payment.currency,
      "amount" => Decimal.to_string(payment.amount),
      "captured_at" => DateTime.to_iso8601(payment.captured_at),
      "recurring" => true
    }

    if renewal? do
      Events.emit!(repo, %{
        polo_id: scope.polo_id,
        aggregate_type: "order",
        aggregate_id: order.id,
        aggregate_version: 1,
        event_type: "order.placed",
        topic: "billing.orders.placed",
        message_key: order.id,
        payload: %{
          "order_id" => order.id,
          "currency" => order.currency,
          "total_amount" => Decimal.to_string(order.total_amount),
          "recurring" => true
        },
        metadata: request_metadata(scope),
        occurred_at: now
      })
    end

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
      payload: %{"order_id" => order.id, "payment_id" => payment.id, "recurring" => true},
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

  defp record_invoice!(repo, scope, agreement, invoice, contract, now) do
    payload = %{
      "consumer_invoice_id" => invoice.id,
      "billing_agreement_id" => agreement.id,
      "access_contract_id" => contract.id,
      "order_id" => invoice.order_id,
      "currency" => invoice.currency,
      "total_amount" => Decimal.to_string(invoice.total_amount),
      "status" => invoice.status,
      "paid_at" => DateTime.to_iso8601(invoice.paid_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "consumer_invoice",
      aggregate_id: invoice.id,
      aggregate_version: 1,
      event_type: "consumer_invoice.paid",
      topic: "billing.consumer_invoices.paid",
      message_key: invoice.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "billing_agreement",
      aggregate_id: agreement.id,
      aggregate_version: next_aggregate_version(repo, scope, "billing_agreement", agreement.id),
      event_type: "billing_agreement.charged",
      topic: "billing.agreements.charged",
      message_key: agreement.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "consumer_invoice.paid",
      resource_type: "consumer_invoice",
      resource_id: invoice.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp next_aggregate_version(repo, scope, type, id) do
    current =
      DomainEvent
      |> where(
        [event],
        event.polo_id == ^scope.polo_id and event.aggregate_type == ^type and
          event.aggregate_id == ^id
      )
      |> repo.aggregate(:max, :aggregate_version)

    (current || 0) + 1
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp reject!(repo, key_id, reason, event, now) do
    if event do
      event
      |> Ecto.Changeset.change(processed_at: now, processing_error: Atom.to_string(reason))
      |> repo.update!()
    end

    Idempotency.fail!(
      repo,
      key_id,
      reason,
      if(event, do: "payment_provider_event"),
      if(event, do: event.id),
      now
    )

    {:denied, reason}
  end

  defp replay(repo, %Key{
         status: "completed",
         resource_type: "consumer_invoice",
         resource_id: invoice_id,
         response_body: %{"access_contract_id" => contract_id}
       }) do
    with %ConsumerInvoice{} = invoice <- repo.get(ConsumerInvoice, invoice_id),
         %AccessContract{} = contract <- repo.get(AccessContract, contract_id) do
      {:accepted, %{invoice: invoice, contract: contract}}
    else
      _missing -> raise "completed recurring invoice points to missing resources"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}),
    do: {:denied, Map.fetch!(@replay_reasons, reason)}

  defp replay(_repo, key), do: raise("invalid recurring invoice replay: #{inspect(key)}")

  defp idempotency_key(request),
    do: compact_key("recurring-invoice", request.provider_invoice_reference)

  defp request_hash(scope, provider, account, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      provider.id,
      account.id,
      request.billing_agreement_reference,
      request.provider_invoice_reference,
      request.provider_payment_reference,
      request.polo_id,
      request.order_id,
      request.amount |> Decimal.normalize() |> Decimal.to_string(:normal),
      request.currency,
      request.occurred_at,
      request.status,
      request.payload
    })
  end

  defp compact_key(prefix, reference) do
    digest = :crypto.hash(:sha256, reference) |> Base.encode16(case: :lower)
    prefix <> ":" <> digest
  end

  defp ensure_order_item_identity!(order_item, source_item) do
    unless order_item.product_offering_version_id == source_item.product_offering_version_id and
             order_item.offering_price_id == source_item.offering_price_id do
      raise "renewal order item changed the frozen commercial identity"
    end
  end

  defp order_number(id), do: "CLB-R-" <> compact_uuid(id)
  defp invoice_number(id), do: "CLBI-" <> compact_uuid(id)
  defp compact_uuid(id), do: id |> String.replace("-", "") |> String.upcase()

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
