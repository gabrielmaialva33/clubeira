defmodule Clubeira.Billing.Gateways.MercadoPago.Refunds do
  @moduledoc false

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago.Client
  alias Clubeira.Billing.Gateways.MercadoPago.Configuration
  alias Clubeira.Billing.Gateways.MercadoPago.Value
  alias Clubeira.Billing.MerchantAccount

  @orders_url "https://api.mercadopago.com/v1/orders"

  @spec refund(MerchantAccount.t(), String.t(), Gateways.refund_request()) ::
          {:ok, Gateways.refunded_payment()} | {:error, atom()}
  def refund(%MerchantAccount{} = account, provider_reference, request)
      when is_binary(provider_reference) and is_map(request) do
    with true <- Value.reference?(provider_reference),
         {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <- request_full_refund(access_token, provider_reference, request),
         {:ok, refund} <- normalize(response, provider_reference, request) do
      {:ok, refund}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def refund(%MerchantAccount{}, _provider_reference, _request),
    do: {:error, :payment_gateway_invalid_response}

  @doc false
  @spec normalize_evidence(Req.Response.t(), String.t()) ::
          {:ok, Gateways.refunded_payment()} | {:error, :payment_gateway_invalid_response}
  def normalize_evidence(
        %Req.Response{
          body: %{
            "id" => response_provider_reference,
            "status" => order_status,
            "status_detail" => order_status_detail,
            "external_reference" => external_reference,
            "total_amount" => total_amount,
            "currency" => currency,
            "last_updated_date" => occurred_at,
            "transactions" => %{
              "payments" => [
                %{
                  "id" => provider_payment_reference,
                  "status" => payment_status,
                  "status_detail" => payment_status_detail,
                  "amount" => payment_amount
                }
              ],
              "refunds" => [
                %{
                  "id" => provider_refund_reference,
                  "transaction_id" => refund_transaction_reference,
                  "amount" => refund_amount,
                  "status" => refund_status
                }
              ]
            }
          }
        },
        provider_reference
      ) do
    with true <- response_provider_reference == provider_reference,
         true <- refunded_status?(order_status, order_status_detail),
         true <- refunded_status?(payment_status, payment_status_detail),
         true <- refund_status == "processed",
         {:ok, total_amount} <- Value.decimal(total_amount),
         {:ok, payment_amount} <- Value.decimal(payment_amount),
         {:ok, refund_amount} <- Value.decimal(refund_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- Decimal.equal?(payment_amount, refund_amount),
         true <- Decimal.positive?(refund_amount),
         true <- Value.currency?(currency),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         {:ok, polo_id, order_id} <- Value.external_reference(external_reference),
         true <- refund_transaction_reference == provider_payment_reference,
         true <- Value.reference?(provider_payment_reference),
         true <- Value.reference?(provider_refund_reference) do
      {:ok,
       %{
         amount: refund_amount,
         currency: currency,
         occurred_at: occurred_at,
         order_id: order_id,
         payload: %{
           "provider" => "mercado_pago",
           "provider_order_id" => provider_reference,
           "provider_payment_id" => provider_payment_reference,
           "provider_refund_id" => provider_refund_reference,
           "order_status" => order_status,
           "order_status_detail" => order_status_detail
         },
         polo_id: polo_id,
         provider_payment_reference: provider_payment_reference,
         provider_reference: provider_reference,
         provider_refund_reference: provider_refund_reference
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  def normalize_evidence(%Req.Response{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp request_full_refund(access_token, provider_reference, request) do
    Client.post(
      url: @orders_url <> "/" <> provider_reference <> "/refund",
      auth: {:bearer, access_token},
      headers: [{"x-idempotency-key", request.idempotency_key}],
      json: %{}
    )
  end

  defp normalize(response, provider_reference, request) do
    with {:ok, refund} <- normalize_evidence(response, provider_reference),
         true <- Decimal.equal?(refund.amount, request.amount),
         true <- refund.currency == request.currency,
         true <- refund.polo_id == request.polo_id and refund.order_id == request.order_id,
         true <- refund.provider_payment_reference == request.provider_payment_reference do
      {:ok, refund}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp refunded_status?(status, "refunded") when status in ["processed", "refunded"],
    do: true

  defp refunded_status?(_status, _detail), do: false
end
