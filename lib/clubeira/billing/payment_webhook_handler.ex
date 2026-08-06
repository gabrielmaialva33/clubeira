defmodule Clubeira.Billing.PaymentWebhookHandler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentSettler
  alias Clubeira.Billing.PaymentTerminator
  alias Clubeira.Billing.RefundSettler
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @maximum_external_id_bytes 255
  @maximum_signature_bytes 512

  @spec handle(String.t(), map()) :: {:ok, atom()} | {:error, atom() | Ecto.Changeset.t()}
  def handle(provider_code, attributes) when is_binary(provider_code) and is_map(attributes) do
    with {:ok, request} <- validate_request(attributes),
         {:ok, account, provider} <- load_account(provider_code, request.merchant_account_id),
         :ok <- authenticate(provider.code, account, request),
         {:ok, provider_payment} <-
           Gateways.fetch_payment(provider.code, account, request.data_id) do
      process_provider_payment(provider_payment, provider, account, request)
    end
  end

  def handle(_provider_code, _attributes), do: {:error, :invalid_webhook}

  defp validate_request(attributes) do
    with {:ok, merchant_account_id} <- Ecto.UUID.cast(attributes[:merchant_account_id]),
         {:ok, internal_request_id} <- Ecto.UUID.cast(attributes[:internal_request_id]),
         data_id when is_binary(data_id) <- attributes[:data_id],
         true <- bounded?(data_id, @maximum_external_id_bytes),
         ^data_id <- attributes[:body_data_id],
         "order" <- attributes[:event_type],
         action when is_binary(action) <- attributes[:event_action],
         true <- String.starts_with?(action, "order."),
         provider_request_id when is_binary(provider_request_id) <-
           attributes[:provider_request_id],
         true <- bounded?(provider_request_id, @maximum_external_id_bytes),
         signature when is_binary(signature) <- attributes[:signature],
         true <- bounded?(signature, @maximum_signature_bytes) do
      {:ok,
       %{
         data_id: data_id,
         internal_request_id: internal_request_id,
         merchant_account_id: merchant_account_id,
         provider_request_id: provider_request_id,
         signature: signature
       }}
    else
      _invalid -> {:error, :invalid_webhook}
    end
  end

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
end
