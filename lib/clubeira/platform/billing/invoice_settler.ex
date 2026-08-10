defmodule Clubeira.Platform.InvoiceSettler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Platform.Invoice
  alias Clubeira.Platform.InvoiceItem
  alias Clubeira.Platform.Payment
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PoloSubscription
  alias Clubeira.Platform.Price
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @maximum_provider_clock_skew_seconds 300

  @type result :: %{
          invoice: Invoice.t(),
          payment: Payment.t(),
          subscription: PoloSubscription.t()
        }

  @spec reconcile(Scope.t(), PaymentProvider.t(), MerchantAccount.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def reconcile(
        %Scope{actor_user_id: nil} = scope,
        %PaymentProvider{} = provider,
        %MerchantAccount{} = account,
        attributes
      )
      when is_map(attributes) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, graph} <- lock_subscription_graph(repo, scope, account, attributes),
           :ok <- validate_invoice(scope, graph, provider, account, attributes, now) do
        reconcile_event(repo, scope, graph, provider, account, attributes, now)
      end
    end)
  end

  def reconcile(%Scope{}, %PaymentProvider{}, %MerchantAccount{}, _attributes),
    do: {:error, :service_scope_required}

  defp lock_subscription_graph(repo, scope, account, attributes) do
    query =
      from subscription in PoloSubscription,
        join: price in Price,
        on:
          price.id == subscription.platform_price_id and
            price.platform_plan_version_id == subscription.platform_plan_version_id,
        join: version in PlanVersion,
        on: version.id == subscription.platform_plan_version_id,
        join: plan in Plan,
        on: plan.id == version.platform_plan_id,
        where:
          subscription.id == ^attributes.platform_subscription_id and
            subscription.polo_id == ^scope.polo_id and
            subscription.merchant_account_id == ^account.id,
        lock: "FOR UPDATE",
        select: %{subscription: subscription, price: price, version: version, plan: plan}

    case repo.one(query) do
      nil -> {:error, :platform_invoice_reconciliation_mismatch}
      graph -> {:ok, graph}
    end
  end

  defp validate_invoice(scope, graph, provider, account, attributes, now) do
    with :ok <- validate_invoice_scope(scope, attributes),
         :ok <- validate_invoice_account(provider, account),
         :ok <- validate_invoice_subscription(graph.subscription, attributes),
         :ok <- validate_invoice_plan(graph),
         :ok <- validate_captured_invoice(attributes),
         :ok <- validate_invoice_amount(graph.price, attributes) do
      validate_invoice_timestamp(graph.subscription, attributes, now)
    end
  end

  defp validate_invoice_scope(scope, attributes) do
    if attributes.billing_scope == :platform and attributes.polo_id == scope.polo_id,
      do: :ok,
      else: {:error, :platform_invoice_reconciliation_mismatch}
  end

  defp validate_invoice_account(provider, account) do
    if account.kind == "platform" and account.status == "active" and provider.status == "active",
      do: :ok,
      else: {:error, :platform_invoice_reconciliation_mismatch}
  end

  defp validate_invoice_subscription(subscription, attributes) do
    cond do
      subscription.provider_reference != attributes.provider_subscription_reference ->
        {:error, :platform_invoice_reconciliation_mismatch}

      subscription.status not in ["pending", "active", "past_due"] ->
        {:error, :platform_subscription_unavailable}

      true ->
        :ok
    end
  end

  defp validate_invoice_plan(graph) do
    if graph.plan.status == "active" and graph.version.status == "published",
      do: :ok,
      else: {:error, :platform_subscription_unavailable}
  end

  defp validate_captured_invoice(attributes) do
    if attributes.status == "captured",
      do: :ok,
      else: {:error, :platform_invoice_reconciliation_mismatch}
  end

  defp validate_invoice_amount(price, attributes) do
    if attributes.currency == price.currency and Decimal.equal?(attributes.amount, price.amount),
      do: :ok,
      else: {:error, :platform_invoice_reconciliation_mismatch}
  end

  defp validate_invoice_timestamp(subscription, attributes, now) do
    earliest = DateTime.add(subscription.inserted_at, -@maximum_provider_clock_skew_seconds)
    latest = DateTime.add(now, @maximum_provider_clock_skew_seconds)

    if DateTime.before?(attributes.occurred_at, earliest) or
         DateTime.after?(attributes.occurred_at, latest),
       do: {:error, :platform_invoice_timestamp_out_of_bounds},
       else: :ok
  end

  defp reconcile_event(repo, scope, graph, provider, account, attributes, now) do
    payload_sha256 = Idempotency.fingerprint(attributes.payload)

    event =
      PaymentProviderEvent
      |> where(
        [event],
        event.payment_provider_id == ^provider.id and
          event.merchant_account_id == ^account.id and
          event.external_event_id == ^attributes.external_event_id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case event do
      nil ->
        provider_event =
          %PaymentProviderEvent{
            payment_provider_id: provider.id,
            merchant_account_id: account.id,
            polo_id: scope.polo_id,
            external_event_id: attributes.external_event_id,
            event_type: "platform_invoice.captured",
            payload: attributes.payload,
            payload_sha256: payload_sha256,
            received_at: now
          }
          |> repo.insert!()

        settle_new(repo, scope, graph, account, attributes, provider_event, now)

      %PaymentProviderEvent{processed_at: %DateTime{}, payload_sha256: ^payload_sha256} ->
        replay(repo, scope, graph.subscription, attributes.provider_invoice_reference)

      %PaymentProviderEvent{} ->
        {:error, :provider_event_conflict}
    end
  end

  defp settle_new(repo, scope, graph, account, attributes, provider_event, now) do
    with {:ok, billing_period} <- billing_period(repo, graph.subscription, graph.price, now) do
      invoice = insert_invoice!(repo, scope, graph, account, attributes, billing_period, now)
      _item = insert_invoice_item!(repo, scope, graph, invoice, now)
      payment = insert_payment!(repo, scope, account, attributes, invoice, now)
      subscription = activate_subscription!(repo, graph.subscription, billing_period, now)
      mark_provider_event_processed!(repo, provider_event, now)
      record_settlement!(repo, scope, graph, subscription, invoice, payment, now)
      {:ok, %{invoice: invoice, payment: payment, subscription: subscription}}
    end
  end

  defp replay(repo, scope, subscription, provider_invoice_reference) do
    invoice =
      repo.one(
        from(invoice in Invoice,
          where:
            invoice.polo_id == ^scope.polo_id and
              invoice.polo_platform_subscription_id == ^subscription.id and
              invoice.provider_reference == ^provider_invoice_reference
        )
      )

    with %Invoice{} = invoice <- invoice,
         %Payment{} = payment <-
           repo.one(
             from(payment in Payment,
               where:
                 payment.polo_id == ^scope.polo_id and
                   payment.platform_invoice_id == ^invoice.id
             )
           ) do
      {:ok, %{invoice: invoice, payment: payment, subscription: subscription}}
    else
      _missing -> {:error, :platform_invoice_reconciliation_mismatch}
    end
  end

  defp insert_invoice!(repo, scope, graph, account, attributes, billing_period, now) do
    id = uuid7()

    %Invoice{
      id: id,
      polo_id: scope.polo_id,
      polo_platform_subscription_id: graph.subscription.id,
      merchant_account_id: account.id,
      provider_reference: attributes.provider_invoice_reference,
      invoice_number: invoice_number(id),
      billing_period: billing_period,
      currency: graph.price.currency,
      subtotal_amount: graph.price.amount,
      discount_amount: Decimal.new(0),
      total_amount: graph.price.amount,
      status: "paid",
      issued_at: now,
      due_at: now,
      paid_at: now,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_invoice_item!(repo, scope, graph, invoice, now) do
    %InvoiceItem{
      polo_id: scope.polo_id,
      platform_invoice_id: invoice.id,
      item_kind: "plan",
      description: graph.version.name,
      quantity: 1,
      unit_amount: graph.price.amount,
      total_amount: graph.price.amount,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_payment!(repo, scope, account, attributes, invoice, now) do
    %Payment{
      polo_id: scope.polo_id,
      platform_invoice_id: invoice.id,
      merchant_account_id: account.id,
      provider_reference: attributes.provider_payment_reference,
      currency: attributes.currency,
      amount: attributes.amount,
      status: "succeeded",
      paid_at: now,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp activate_subscription!(repo, subscription, billing_period, now) do
    subscription
    |> Ecto.Changeset.change(
      status: "active",
      current_period: billing_period,
      next_action: %{},
      next_charge_at: billing_period.upper,
      updated_at: now
    )
    |> repo.update!()
  end

  defp billing_period(repo, subscription, price, now) do
    lower =
      case subscription.current_period do
        nil -> now
        %Postgrex.Range{upper: %DateTime{} = upper} -> upper
        _invalid -> nil
      end

    with %DateTime{} <- lower,
         {:ok, interval} <- interval_expression(price.billing_interval_unit) do
      sql = "SELECT ($1::timestamptz + #{interval})"
      %{rows: [[upper]]} = repo.query!(sql, [lower, price.billing_interval_count])

      {:ok,
       %Postgrex.Range{
         lower: lower,
         upper: upper,
         lower_inclusive: true,
         upper_inclusive: false
       }}
    else
      _invalid -> {:error, :platform_subscription_unavailable}
    end
  end

  defp interval_expression("month"), do: {:ok, "make_interval(months => $2)"}
  defp interval_expression("year"), do: {:ok, "make_interval(years => $2)"}
  defp interval_expression(_unit), do: {:error, :platform_subscription_unavailable}

  defp record_settlement!(repo, scope, graph, subscription, invoice, payment, now) do
    payload = %{
      "platform_invoice_id" => invoice.id,
      "polo_platform_subscription_id" => subscription.id,
      "platform_plan_version_id" => graph.version.id,
      "platform_payment_id" => payment.id,
      "currency" => invoice.currency,
      "amount" => Decimal.to_string(invoice.total_amount),
      "status" => invoice.status,
      "paid_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "platform_invoice",
      aggregate_id: invoice.id,
      aggregate_version: 1,
      event_type: "platform_invoice.paid",
      topic: "platform.billing.invoices.paid",
      message_key: invoice.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "platform_invoice.paid",
      resource_type: "platform_invoice",
      resource_id: invoice.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp invoice_number(id) do
    suffix = id |> String.replace("-", "") |> String.upcase()
    "PLT-" <> suffix
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
