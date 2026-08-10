defmodule Clubeira.Billing.Gateways.MercadoPago.Chargebacks do
  @moduledoc false

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago.Client
  alias Clubeira.Billing.Gateways.MercadoPago.Configuration
  alias Clubeira.Billing.Gateways.MercadoPago.Value
  alias Clubeira.Billing.MerchantAccount

  @chargebacks_url "https://api.mercadopago.com/v1/chargebacks"
  @payments_url "https://api.mercadopago.com/v1/payments"

  @spec fetch(MerchantAccount.t(), String.t()) ::
          {:ok, Gateways.chargeback()} | {:error, atom()}
  def fetch(%MerchantAccount{} = account, provider_reference)
      when is_binary(provider_reference) do
    with true <- Value.reference?(provider_reference),
         {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <-
           Client.get(
             url: @chargebacks_url <> "/" <> provider_reference,
             auth: {:bearer, access_token}
           ),
         {:ok, evidence} <- normalize(response, provider_reference),
         {:ok, payment_response} <-
           Client.get(
             url: @payments_url <> "/" <> evidence.provider_payment_reference,
             auth: {:bearer, access_token}
           ),
         {:ok, polo_id} <- normalize_payment(payment_response, evidence) do
      {:ok, Map.put(evidence, :polo_id, polo_id)}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def fetch(%MerchantAccount{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp normalize(
         %Req.Response{
           body:
             %{
               "id" => response_reference,
               "payments" => [provider_payment_reference],
               "currency" => currency,
               "amount" => amount,
               "coverage_applied" => coverage_applied,
               "documentation_status" => documentation_status,
               "date_created" => opened_at,
               "date_last_updated" => occurred_at
             } = body
         },
         provider_reference
       ) do
    with ^provider_reference <- Value.reference_string(response_reference),
         provider_payment_reference when is_binary(provider_payment_reference) <-
           Value.reference_string(provider_payment_reference),
         true <- Value.reference?(provider_payment_reference),
         true <- Value.currency?(currency),
         {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.positive?(amount),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         {:ok, opened_at} <- chargeback_opened_at(opened_at, occurred_at),
         {:ok, status} <- chargeback_status(coverage_applied, documentation_status),
         reason_code <- optional_reference(body["reason"]) do
      {:ok,
       %{
         amount: amount,
         closed_at: if(status in ["won", "lost"], do: occurred_at),
         currency: currency,
         occurred_at: occurred_at,
         opened_at: opened_at,
         payload: %{
           "provider" => "mercado_pago",
           "provider_chargeback_id" => provider_reference,
           "provider_payment_id" => provider_payment_reference,
           "status" => status,
           "documentation_status" => documentation_status
         },
         provider_payment_reference: provider_payment_reference,
         provider_reference: provider_reference,
         reason_code: reason_code,
         status: status
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize(%Req.Response{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp normalize_payment(
         %Req.Response{
           body: %{
             "id" => response_payment_reference,
             "external_reference" => external_reference,
             "currency_id" => currency,
             "transaction_amount" => amount
           }
         },
         evidence
       ) do
    expected_payment_reference = evidence.provider_payment_reference

    with ^expected_payment_reference <- Value.reference_string(response_payment_reference),
         true <- currency == evidence.currency,
         {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.positive?(amount),
         {:ok, polo_id, _route_order_id} <- Value.external_reference(external_reference) do
      {:ok, polo_id}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_payment(%Req.Response{}, _evidence),
    do: {:error, :payment_gateway_invalid_response}

  defp chargeback_opened_at(nil, occurred_at), do: {:ok, occurred_at}
  defp chargeback_opened_at(value, _occurred_at), do: Value.datetime(value)

  defp chargeback_status(true, _documentation_status), do: {:ok, "won"}
  defp chargeback_status(false, _documentation_status), do: {:ok, "lost"}

  defp chargeback_status(nil, documentation_status)
       when documentation_status in ["review_pending", "valid"],
       do: {:ok, "under_review"}

  defp chargeback_status(nil, documentation_status)
       when documentation_status in ["not_supplied", "pending", nil],
       do: {:ok, "open"}

  defp chargeback_status(_coverage_applied, _documentation_status), do: :error

  defp optional_reference(nil), do: nil

  defp optional_reference(value) when is_binary(value) do
    if Value.reference?(value), do: value
  end

  defp optional_reference(_value), do: nil
end
