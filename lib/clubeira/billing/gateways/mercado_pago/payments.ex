defmodule Clubeira.Billing.Gateways.MercadoPago.Payments do
  @moduledoc false

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago.Client
  alias Clubeira.Billing.Gateways.MercadoPago.Configuration
  alias Clubeira.Billing.Gateways.MercadoPago.Refunds
  alias Clubeira.Billing.Gateways.MercadoPago.Value
  alias Clubeira.Billing.MerchantAccount

  @orders_url "https://api.mercadopago.com/v1/orders"
  @pix_expiration "PT30M"

  @spec create(MerchantAccount.t(), Gateways.payment_request()) ::
          {:ok, Gateways.created_payment()} | {:error, atom()}
  def create(%MerchantAccount{} = account, request) when is_map(request) do
    with {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <- request_pix_order(access_token, request) do
      normalize_created_pix(response, request.amount)
    end
  end

  def create(%MerchantAccount{}, _request), do: {:error, :payment_gateway_invalid_response}

  @spec fetch(MerchantAccount.t(), String.t()) ::
          {:ok,
           :pending
           | {:terminal, Gateways.terminal_payment()}
           | {:refunded, Gateways.refunded_payment()}
           | Gateways.captured_payment()}
          | {:error, atom()}
  def fetch(%MerchantAccount{} = account, provider_reference)
      when is_binary(provider_reference) do
    with true <- Value.reference?(provider_reference),
         {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <-
           Client.get(
             url: @orders_url <> "/" <> provider_reference,
             auth: {:bearer, access_token}
           ),
         {:ok, payment} <- normalize_order(response, provider_reference) do
      {:ok, payment}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def fetch(%MerchantAccount{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp request_pix_order(access_token, request) do
    Client.post(
      url: @orders_url,
      auth: {:bearer, access_token},
      headers: [{"x-idempotency-key", request.idempotency_key}],
      json: %{
        type: "online",
        total_amount: Value.decimal_string(request.amount),
        external_reference: "#{request.polo_id}_#{request.order_id}",
        processing_mode: "automatic",
        payer: %{email: request.payer_email},
        transactions: %{
          payments: [
            %{
              amount: Value.decimal_string(request.amount),
              payment_method: %{id: "pix", type: "bank_transfer"},
              expiration_time: @pix_expiration
            }
          ]
        }
      }
    )
  end

  defp normalize_created_pix(
         %Req.Response{
           body: %{
             "id" => provider_reference,
             "status" => "action_required",
             "transactions" => %{
               "payments" => [
                 %{
                   "id" => provider_payment_reference,
                   "amount" => amount,
                   "payment_method" => %{
                     "id" => "pix",
                     "type" => "bank_transfer",
                     "ticket_url" => redirect_url,
                     "qr_code" => copy_paste_code
                   }
                 }
               ]
             }
           }
         },
         expected_amount
       ) do
    with {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.equal?(amount, expected_amount),
         true <- Value.reference?(provider_reference),
         true <- Value.reference?(provider_payment_reference),
         true <- Value.redirect_url?(redirect_url),
         true <- Value.pix_code?(copy_paste_code) do
      {:ok,
       %{
         amount: amount,
         provider_reference: provider_reference,
         provider_payment_reference: provider_payment_reference,
         next_action: %{
           "type" => "pix",
           "redirect_url" => redirect_url,
           "copy_paste_code" => copy_paste_code
         }
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_created_pix(%Req.Response{}, _expected_amount),
    do: {:error, :payment_gateway_invalid_response}

  defp normalize_order(
         %Req.Response{body: %{"status" => status, "status_detail" => "refunded"}} = response,
         provider_reference
       )
       when status in ["processed", "refunded"] do
    case Refunds.normalize_evidence(response, provider_reference) do
      {:ok, refund} -> {:ok, {:refunded, refund}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_order(
         %Req.Response{
           body: %{
             "id" => provider_reference,
             "status" => "processed",
             "status_detail" => "accredited",
             "external_reference" => external_reference,
             "total_amount" => total_amount,
             "currency" => currency,
             "last_updated_date" => occurred_at,
             "transactions" => %{
               "payments" => [
                 %{
                   "id" => provider_payment_reference,
                   "status" => "processed",
                   "status_detail" => "accredited",
                   "amount" => payment_amount
                 }
               ]
             }
           }
         },
         provider_reference
       ) do
    with {:ok, total_amount} <- Value.decimal(total_amount),
         {:ok, payment_amount} <- Value.decimal(payment_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- Value.currency?(currency),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         {:ok, polo_id, order_id} <- Value.external_reference(external_reference),
         true <- Value.reference?(provider_payment_reference) do
      {:ok,
       %{
         amount: payment_amount,
         currency: currency,
         occurred_at: occurred_at,
         order_id: order_id,
         payload: %{
           "provider" => "mercado_pago",
           "provider_order_id" => provider_reference,
           "provider_payment_id" => provider_payment_reference,
           "order_status" => "processed",
           "order_status_detail" => "accredited"
         },
         polo_id: polo_id,
         provider_payment_reference: provider_payment_reference,
         provider_reference: provider_reference
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_order(
         %Req.Response{body: %{"id" => provider_reference, "status" => status}},
         provider_reference
       )
       when status in ["created", "action_required", "processing"],
       do: {:ok, :pending}

  defp normalize_order(
         %Req.Response{
           body: %{
             "id" => provider_reference,
             "status" => status,
             "status_detail" => status_detail,
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
               ]
             }
           }
         },
         provider_reference
       ) do
    with {:ok, status} <- terminal_status(status),
         {:ok, ^status} <- terminal_status(payment_status),
         {:ok, total_amount} <- Value.decimal(total_amount),
         {:ok, payment_amount} <- Value.decimal(payment_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- Value.currency?(currency),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         {:ok, polo_id, order_id} <- Value.external_reference(external_reference),
         true <- Value.reference?(provider_payment_reference),
         true <- Value.reference?(status_detail),
         true <- Value.reference?(payment_status_detail) do
      {:ok,
       {:terminal,
        %{
          amount: payment_amount,
          currency: currency,
          occurred_at: occurred_at,
          order_id: order_id,
          payload: %{
            "provider" => "mercado_pago",
            "provider_order_id" => provider_reference,
            "provider_payment_id" => provider_payment_reference,
            "order_status" => status,
            "order_status_detail" => status_detail
          },
          polo_id: polo_id,
          provider_reference: provider_reference,
          status: status
        }}}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_order(%Req.Response{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp terminal_status("expired"), do: {:ok, "expired"}
  defp terminal_status("failed"), do: {:ok, "failed"}
  defp terminal_status(status) when status in ["canceled", "cancelled"], do: {:ok, "cancelled"}
  defp terminal_status(_status), do: :error
end
