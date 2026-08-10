defmodule Clubeira.Billing.PaymentStarter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentStartRequest
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Events
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @pix_expiration_seconds 30 * 60

  @type started_payment :: %{payment_intent: PaymentIntent.t(), provider: String.t()}

  @spec start(Scope.t(), map()) ::
          {:ok, started_payment()} | {:error, atom() | Ecto.Changeset.t()}
  def start(%Scope{actor_user_id: nil}, _attributes), do: {:error, :actor_required}

  def start(%Scope{} = scope, attributes) do
    with {:ok, request} <- PaymentStartRequest.new(attributes),
         {:ok, reservation} <- reserve(scope, request) do
      start_reserved(scope, reservation)
    end
  end

  def start(_scope, _attributes), do: {:error, :actor_required}

  defp reserve(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, order, purchaser} <- lock_order(repo, scope, request.order_id),
           :ok <- ensure_payable(order),
           {:ok, provider_code} <- Gateways.provider_for_payment(request.payment_method),
           {:ok, account, provider} <- lock_gateway_account(repo, scope, now, provider_code),
           {:ok, intent} <- reserve_intent(repo, scope, order, account, request, now) do
        {:ok,
         %{
           account: account,
           intent: intent,
           order: order,
           provider: provider,
           purchaser: purchaser,
           request: request
         }}
      end
    end)
  end

  defp start_reserved(_scope, %{intent: %PaymentIntent{status: "requires_action"}} = reservation) do
    {:ok, result(reservation)}
  end

  defp start_reserved(scope, %{intent: %PaymentIntent{status: "created"}} = reservation) do
    gateway_request = %{
      amount: reservation.order.total_amount,
      currency: reservation.order.currency,
      idempotency_key: reservation.intent.id,
      order_id: reservation.order.id,
      polo_id: scope.polo_id,
      payer_email: reservation.purchaser.email
    }

    with {:ok, provider_payment} <-
           Gateways.create_payment(
             reservation.provider.code,
             reservation.account,
             reservation.request.payment_method,
             gateway_request
           ),
         {:ok, payment_intent} <- finalize(scope, reservation, provider_payment) do
      {:ok, %{payment_intent: payment_intent, provider: reservation.provider.code}}
    end
  end

  defp start_reserved(_scope, _reservation), do: {:error, :payment_intent_unavailable}

  defp lock_order(repo, scope, order_id) do
    query =
      from order in Order,
        join: purchaser in User,
        on: purchaser.id == order.purchaser_user_id,
        where:
          order.id == ^order_id and order.polo_id == ^scope.polo_id and
            order.purchaser_user_id == ^scope.actor_user_id,
        lock: "FOR UPDATE",
        select: {order, purchaser}

    case repo.one(query) do
      {%Order{} = order, %User{status: "active"} = purchaser} ->
        {:ok, order, purchaser}

      _missing_or_unavailable ->
        {:error, :order_not_found}
    end
  end

  defp ensure_payable(%Order{status: status, total_amount: amount, currency: "BRL"})
       when status in ["pending", "awaiting_payment"] do
    if Decimal.positive?(amount), do: :ok, else: {:error, :order_not_payable}
  end

  defp ensure_payable(%Order{}), do: {:error, :order_not_payable}

  defp lock_gateway_account(repo, scope, now, provider_code) do
    query = gateway_account_query(scope, now, provider_code)

    case repo.one(query) do
      {%MerchantAccount{} = account, %PaymentProvider{} = provider} ->
        {:ok, account, provider}

      nil ->
        {:error, :payment_gateway_unavailable}
    end
  end

  defp gateway_account_query(scope, now, provider_code) do
    from assignment in PoloMerchantAccount,
      join: account in MerchantAccount,
      on: account.id == assignment.merchant_account_id,
      join: provider in PaymentProvider,
      on: provider.id == assignment.payment_provider_id,
      where: assignment.polo_id == ^scope.polo_id,
      where: assignment.role == "primary",
      where: account.payment_provider_id == provider.id,
      where: account.kind == "consumer" and account.status == "active",
      where: provider.status == "active" and provider.code == ^provider_code,
      where:
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          assignment.valid_during,
          type(^now, :utc_datetime_usec)
        ),
      order_by: [asc: account.id],
      limit: 1,
      lock: "FOR SHARE",
      select: {account, provider}
  end

  defp reserve_intent(repo, scope, order, account, request, now) do
    existing_query =
      from intent in PaymentIntent,
        where:
          intent.polo_id == ^scope.polo_id and intent.order_id == ^order.id and
            intent.idempotency_key == ^request.idempotency_key,
        lock: "FOR UPDATE"

    case repo.one(existing_query) do
      %PaymentIntent{} = intent ->
        if intent.payment_method in [nil, request.payment_method] do
          {:ok, intent}
        else
          {:error, :idempotency_conflict}
        end

      nil ->
        insert_intent(repo, scope, order, account, request, now)
    end
  end

  defp insert_intent(repo, scope, order, account, request, now) do
    %PaymentIntent{
      polo_id: scope.polo_id,
      order_id: order.id,
      merchant_account_id: account.id,
      idempotency_key: request.idempotency_key,
      payment_method: request.payment_method,
      currency: order.currency,
      amount: order.total_amount,
      status: "created",
      expires_at: DateTime.add(now, @pix_expiration_seconds),
      next_action: %{},
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:idempotency_key,
      name: :payment_intents_order_idempotency_uidx
    )
    |> Ecto.Changeset.unique_constraint(:order_id, name: :payment_intents_live_order_uidx)
    |> repo.insert(mode: :savepoint)
    |> case do
      {:ok, intent} -> {:ok, intent}
      {:error, %Ecto.Changeset{} = changeset} -> intent_error(changeset)
    end
  end

  defp intent_error(changeset) do
    if constraint_error?(changeset, "payment_intents_live_order_uidx") do
      {:error, :payment_already_started}
    else
      {:error, changeset}
    end
  end

  defp constraint_error?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      to_string(options[:constraint_name]) == name
    end)
  end

  defp finalize(scope, reservation, provider_payment) do
    Repo.transact_in_polo(scope, fn repo ->
      intent =
        PaymentIntent
        |> where(
          [intent],
          intent.id == ^reservation.intent.id and intent.polo_id == ^scope.polo_id
        )
        |> lock("FOR UPDATE")
        |> repo.one!()

      with :ok <- validate_provider_payment(intent, provider_payment),
           {:ok, updated} <- update_intent(repo, intent, provider_payment) do
        record_started!(repo, scope, updated)
        {:ok, updated}
      end
    end)
  end

  defp validate_provider_payment(intent, provider_payment) do
    cond do
      intent.status != "created" ->
        {:error, :payment_intent_unavailable}

      not Decimal.equal?(intent.amount, provider_payment.amount) ->
        {:error, :payment_gateway_invalid_response}

      true ->
        :ok
    end
  end

  defp update_intent(repo, intent, provider_payment) do
    intent
    |> Ecto.Changeset.change(
      provider_reference: provider_payment.provider_reference,
      status: "requires_action",
      next_action: provider_payment.next_action,
      updated_at: transaction_time(repo)
    )
    |> Ecto.Changeset.unique_constraint(:provider_reference,
      name: :payment_intents_provider_reference_uidx
    )
    |> repo.update()
  end

  defp record_started!(repo, scope, intent) do
    payload = %{
      "payment_intent_id" => intent.id,
      "order_id" => intent.order_id,
      "payment_method" => intent.payment_method,
      "currency" => intent.currency,
      "amount" => Decimal.to_string(intent.amount),
      "expires_at" => DateTime.to_iso8601(intent.expires_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "payment_intent",
      aggregate_id: intent.id,
      aggregate_version: 1,
      event_type: "payment_intent.requires_action",
      topic: "billing.payment_intents.requires_action",
      message_key: intent.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: intent.updated_at
    })

    Audit.record_tenant!(repo, scope, %{
      action: "payment_intent.requires_action",
      resource_type: "payment_intent",
      resource_id: intent.id,
      metadata: payload,
      occurred_at: intent.updated_at
    })
  end

  defp result(reservation) do
    %{payment_intent: reservation.intent, provider: reservation.provider.code}
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
