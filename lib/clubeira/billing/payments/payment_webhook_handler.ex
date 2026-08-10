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

  @spec handle(String.t(), map()) :: {:ok, atom()} | {:error, atom() | Ecto.Changeset.t()}
  def handle(provider_code, attributes) when is_binary(provider_code) and is_map(attributes) do
    with {:ok, request} <- validate_request(attributes),
         {:ok, account, provider} <- load_account(provider_code, request.merchant_account_id),
         {:ok, event} <- Gateways.verify_webhook(provider.code, account, request.envelope) do
      fetch_and_process(provider, account, request, event)
    end
  end

  def handle(_provider_code, _attributes), do: {:error, :invalid_webhook}

  defp validate_request(attributes) do
    with {:ok, merchant_account_id} <- Ecto.UUID.cast(attributes[:merchant_account_id]),
         {:ok, internal_request_id} <- Ecto.UUID.cast(attributes[:internal_request_id]),
         %{body_params: body, headers: headers, query_params: query, raw_body: raw_body} =
           envelope <-
           attributes[:envelope],
         true <- is_map(body) and is_map(headers) and is_map(query) and is_binary(raw_body) do
      {:ok,
       %{
         envelope: envelope,
         internal_request_id: internal_request_id,
         merchant_account_id: merchant_account_id
       }}
    else
      _invalid -> {:error, :invalid_webhook}
    end
  end

  defp fetch_and_process(
         provider,
         account,
         request,
         %{
           kind: :payment,
           provider_reference: provider_reference
         } = event
       ) do
    with {:ok, provider_payment} <-
           Gateways.fetch_payment(provider.code, account, provider_reference) do
      process_provider_payment(provider_payment, provider, account, request, event)
    end
  end

  defp fetch_and_process(
         provider,
         account,
         request,
         %{
           kind: :recurring_invoice,
           provider_reference: provider_reference
         } = event
       ) do
    with {:ok, invoice} <-
           Gateways.fetch_recurring_invoice(provider.code, account, provider_reference) do
      process_recurring_invoice(invoice, provider, account, request, event)
    end
  end

  defp fetch_and_process(provider, account, request, %{
         kind: :chargeback,
         provider_reference: provider_reference,
         provider_payment_reference: payment_reference
       }) do
    with true <- is_binary(payment_reference),
         {:ok, chargeback} <-
           Gateways.fetch_chargeback(provider.code, account, provider_reference),
         true <- chargeback.provider_payment_reference == payment_reference do
      process_chargeback(chargeback, provider, account, request)
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_and_process(_provider, _account, _request, _event),
    do: {:error, :payment_gateway_invalid_response}

  defp process_recurring_invoice(invoice, provider, account, request, event) do
    scope = Scope.new!(invoice.polo_id, request_id: request.internal_request_id)
    attributes = Map.put(invoice, :external_event_id, event.external_event_id)

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

  defp process_provider_payment(:pending, _provider, _account, _request, _event) do
    {:ok, :acknowledged}
  end

  defp process_provider_payment({:terminal, payment}, provider, account, request, event) do
    scope = Scope.new!(payment.polo_id, request_id: request.internal_request_id)

    case PaymentTerminator.terminate(
           scope,
           provider,
           account,
           event.external_event_id,
           payment
         ) do
      {:ok, _intent} -> {:ok, :processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_provider_payment(
         {:refunded, provider_refund},
         provider,
         account,
         request,
         _event
       ) do
    scope = Scope.new!(provider_refund.polo_id, request_id: request.internal_request_id)

    case RefundSettler.reconcile(scope, provider, account, provider_refund) do
      {:ok, _refund} -> {:ok, :processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_provider_payment(provider_payment, provider, account, request, event)
       when is_map(provider_payment) do
    scope = Scope.new!(provider_payment.polo_id, request_id: request.internal_request_id)

    attributes = %{
      order_id: provider_payment.order_id,
      payment_provider_id: provider.id,
      merchant_account_id: account.id,
      external_event_id: event.external_event_id,
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
end
