defmodule Clubeira.Billing.PaymentWebhookHandler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.ChargebackSettler
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentSettler
  alias Clubeira.Billing.PaymentTerminator
  alias Clubeira.Billing.RecurringInvoiceSettler
  alias Clubeira.Billing.RefundSettler
  alias Clubeira.Platform.InvoiceSettler, as: PlatformInvoiceSettler
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @maximum_external_id_bytes 255
  @maximum_signature_bytes 512
  @event_types ~w(order subscription_authorized_payment topic_chargebacks_wh)

  @spec handle(String.t(), map()) :: {:ok, atom()} | {:error, atom() | Ecto.Changeset.t()}
  def handle(provider_code, attributes) when is_binary(provider_code) and is_map(attributes) do
    with {:ok, request} <- validate_request(attributes),
         {:ok, account, provider} <- load_account(provider_code, request.merchant_account_id),
         :ok <- authenticate(provider.code, account, request) do
      fetch_and_process(provider, account, request)
    end
  end

  def handle(_provider_code, _attributes), do: {:error, :invalid_webhook}

  defp validate_request(attributes) do
    with {:ok, merchant_account_id} <- Ecto.UUID.cast(attributes[:merchant_account_id]),
         {:ok, internal_request_id} <- Ecto.UUID.cast(attributes[:internal_request_id]),
         data_id when is_binary(data_id) <- attributes[:data_id],
         true <- bounded?(data_id, @maximum_external_id_bytes),
         ^data_id <- reference_string(attributes[:body_data_id]),
         event_type when event_type in @event_types <- attributes[:event_type],
         true <- valid_action?(event_type, attributes),
         provider_request_id when is_binary(provider_request_id) <-
           attributes[:provider_request_id],
         true <- bounded?(provider_request_id, @maximum_external_id_bytes),
         signature when is_binary(signature) <- attributes[:signature],
         true <- bounded?(signature, @maximum_signature_bytes) do
      {:ok,
       %{
         data_id: data_id,
         body_payment_reference: reference_string(attributes[:body_payment_id]),
         internal_request_id: internal_request_id,
         merchant_account_id: merchant_account_id,
         provider_request_id: provider_request_id,
         signature: signature,
         event_type: event_type
       }}
    else
      _invalid -> {:error, :invalid_webhook}
    end
  end

  defp fetch_and_process(provider, account, %{event_type: "order"} = request) do
    with {:ok, provider_payment} <-
           Gateways.fetch_payment(provider.code, account, request.data_id) do
      process_provider_payment(provider_payment, provider, account, request)
    end
  end

  defp fetch_and_process(
         provider,
         account,
         %{event_type: "subscription_authorized_payment"} = request
       ) do
    with {:ok, invoice} <-
           Gateways.fetch_recurring_invoice(provider.code, account, request.data_id) do
      process_recurring_invoice(invoice, provider, account, request)
    end
  end

  defp fetch_and_process(
         provider,
         account,
         %{event_type: "topic_chargebacks_wh"} = request
       ) do
    with payment_reference when is_binary(payment_reference) <-
           request.body_payment_reference,
         {:ok, chargeback} <-
           Gateways.fetch_chargeback(provider.code, account, request.data_id),
         true <- chargeback.provider_payment_reference == payment_reference do
      process_chargeback(chargeback, provider, account, request)
    else
      false -> {:error, :payment_gateway_invalid_response}
      nil -> {:error, :invalid_webhook}
      {:error, _reason} = error -> error
    end
  end

  defp process_recurring_invoice(invoice, provider, account, request) do
    scope = Scope.new!(invoice.polo_id, request_id: request.internal_request_id)

    attributes =
      Map.put(
        invoice,
        :external_event_id,
        "subscription_authorized_payment:#{invoice.provider_invoice_reference}"
      )

    invoice.billing_scope
    |> reconcile_invoice(scope, provider, account, attributes)
    |> processed_result()
  end

  defp reconcile_invoice(:consumer, scope, provider, account, attributes),
    do: RecurringInvoiceSettler.reconcile(scope, provider, account, attributes)

  defp reconcile_invoice(:platform, scope, provider, account, attributes),
    do: PlatformInvoiceSettler.reconcile(scope, provider, account, attributes)

  defp process_chargeback(chargeback, provider, account, request) do
    scope = Scope.new!(chargeback.polo_id, request_id: request.internal_request_id)

    scope
    |> ChargebackSettler.reconcile(provider, account, chargeback)
    |> processed_result()
  end

  defp processed_result({:ok, _result}), do: {:ok, :processed}
  defp processed_result({:error, reason}), do: {:error, reason}

  defp load_account(provider_code, merchant_account_id) do
    query =
      from account in MerchantAccount,
        join: provider in PaymentProvider,
        on: provider.id == account.payment_provider_id,
        where: account.id == ^merchant_account_id and provider.code == ^provider_code,
        select: {account, provider}

    case Repo.one(query) do
      {%MerchantAccount{} = account, %PaymentProvider{} = provider} ->
        {:ok, account, provider}

      nil ->
        {:error, :webhook_unauthorized}
    end
  end

  defp authenticate(provider_code, account, request) do
    case Gateways.authenticate_webhook(
           provider_code,
           account,
           request.data_id,
           request.provider_request_id,
           request.signature
         ) do
      :ok -> :ok
      {:error, :payment_gateway_not_configured} = error -> error
      {:error, _reason} -> {:error, :webhook_unauthorized}
    end
  end

  defp process_provider_payment(:pending, _provider, _account, _request) do
    {:ok, :acknowledged}
  end

  defp process_provider_payment({:terminal, payment}, provider, account, request) do
    scope = Scope.new!(payment.polo_id, request_id: request.internal_request_id)

    case PaymentTerminator.terminate(
           scope,
           provider,
           account,
           request.provider_request_id,
           payment
         ) do
      {:ok, _intent} -> {:ok, :processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_provider_payment({:refunded, provider_refund}, provider, account, request) do
    scope = Scope.new!(provider_refund.polo_id, request_id: request.internal_request_id)

    case RefundSettler.reconcile(scope, provider, account, provider_refund) do
      {:ok, _refund} -> {:ok, :processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_provider_payment(provider_payment, provider, account, request)
       when is_map(provider_payment) do
    scope = Scope.new!(provider_payment.polo_id, request_id: request.internal_request_id)

    attributes = %{
      order_id: provider_payment.order_id,
      payment_provider_id: provider.id,
      merchant_account_id: account.id,
      external_event_id: request.provider_request_id,
      provider_intent_reference: provider_payment.provider_reference,
      provider_reference: provider_payment.provider_payment_reference,
      amount: provider_payment.amount,
      currency: provider_payment.currency,
      occurred_at: provider_payment.occurred_at,
      payload: provider_payment.payload
    }

    case PaymentSettler.settle(scope, attributes) do
      {:ok, _contract} -> {:ok, :processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded?(value, maximum) do
    byte_size(value) in 1..maximum
  end

  defp valid_action?("order", %{event_action: action}) when is_binary(action),
    do: String.starts_with?(action, "order.")

  defp valid_action?("subscription_authorized_payment", %{event_action: action})
       when is_binary(action) do
    bounded?(action, @maximum_external_id_bytes)
  end

  defp valid_action?("topic_chargebacks_wh", %{event_actions: actions})
       when is_list(actions) do
    actions != [] and
      Enum.all?(actions, fn action ->
        is_binary(action) and bounded?(action, @maximum_external_id_bytes)
      end)
  end

  defp valid_action?(_event_type, _attributes), do: false

  defp reference_string(value) when is_binary(value), do: value
  defp reference_string(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp reference_string(_value), do: nil
end
