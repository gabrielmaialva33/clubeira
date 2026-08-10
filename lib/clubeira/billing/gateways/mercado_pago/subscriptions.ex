defmodule Clubeira.Billing.Gateways.MercadoPago.Subscriptions do
  @moduledoc false

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago.Client
  alias Clubeira.Billing.Gateways.MercadoPago.Configuration
  alias Clubeira.Billing.Gateways.MercadoPago.Value
  alias Clubeira.Billing.MerchantAccount

  @authorized_payments_url "https://api.mercadopago.com/authorized_payments"
  @subscriptions_url "https://api.mercadopago.com/preapproval"
  @maximum_back_url_bytes 2_048

  @spec create(MerchantAccount.t(), Gateways.subscription_request()) ::
          {:ok, Gateways.created_subscription()} | {:error, atom()}
  def create(%MerchantAccount{} = account, request) when is_map(request) do
    with {:ok, back_url} <- Configuration.subscription_back_url(),
         true <- valid_back_url?(back_url),
         {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <- request_subscription(access_token, request, back_url),
         {:ok, subscription} <- normalize_created(response, request) do
      {:ok, subscription}
    else
      false -> {:error, :payment_gateway_not_configured}
      {:error, _reason} = error -> error
    end
  end

  def create(%MerchantAccount{}, _request), do: {:error, :payment_gateway_invalid_response}

  @spec fetch_invoice(MerchantAccount.t(), String.t()) ::
          {:ok, Gateways.recurring_invoice() | Gateways.platform_invoice()} | {:error, atom()}
  def fetch_invoice(%MerchantAccount{} = account, provider_reference)
      when is_binary(provider_reference) do
    with true <- Value.reference?(provider_reference),
         {:ok, access_token} <- Configuration.access_token(account.provider_account_reference),
         {:ok, response} <-
           Client.get(
             url: @authorized_payments_url <> "/" <> provider_reference,
             auth: {:bearer, access_token}
           ),
         {:ok, invoice} <- normalize_invoice(response, provider_reference) do
      {:ok, invoice}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def fetch_invoice(%MerchantAccount{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp request_subscription(access_token, request, back_url) do
    Client.post(
      url: @subscriptions_url,
      auth: {:bearer, access_token},
      headers: [{"x-idempotency-key", request.idempotency_key}],
      json: %{
        reason: request.reason,
        external_reference: request.external_reference,
        payer_email: request.payer_email,
        auto_recurring: %{
          frequency: request.interval.frequency,
          frequency_type: request.interval.type,
          transaction_amount: Value.decimal_string(request.amount),
          currency_id: request.currency
        },
        back_url: back_url
      }
    )
  end

  defp normalize_created(
         %Req.Response{
           body:
             %{
               "id" => provider_reference,
               "external_reference" => external_reference,
               "status" => provider_status,
               "auto_recurring" => %{
                 "frequency" => frequency,
                 "frequency_type" => frequency_type,
                 "transaction_amount" => amount,
                 "currency_id" => currency
               }
             } = body
         },
         request
       ) do
    with true <- Value.reference?(provider_reference),
         true <- external_reference == request.external_reference,
         {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.equal?(amount, request.amount),
         true <- currency == request.currency,
         true <- frequency == request.interval.frequency,
         true <- frequency_type == request.interval.type,
         {:ok, status} <- subscription_status(provider_status),
         {:ok, next_action} <- subscription_next_action(body, status),
         {:ok, next_charge_at} <- optional_datetime(body["next_payment_date"]) do
      {:ok,
       %{
         amount: amount,
         next_action: next_action,
         next_charge_at: next_charge_at,
         provider_reference: provider_reference,
         status: status
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_created(%Req.Response{}, _request),
    do: {:error, :payment_gateway_invalid_response}

  defp normalize_invoice(
         %Req.Response{
           body: %{
             "id" => response_invoice_reference,
             "preapproval_id" => subscription_reference,
             "external_reference" => "platform:" <> platform_reference,
             "currency_id" => currency,
             "transaction_amount" => amount,
             "last_modified" => occurred_at,
             "payment" => %{
               "id" => payment_reference,
               "status" => "approved",
               "status_detail" => status_detail
             }
           }
         },
         provider_reference
       )
       when status_detail in ["accredited", "approved"] do
    with ^provider_reference <- Value.reference_string(response_invoice_reference),
         true <- Value.reference?(subscription_reference),
         {:ok, polo_id, platform_subscription_id} <-
           Value.platform_external_reference(platform_reference),
         true <- Value.currency?(currency),
         {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.positive?(amount),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         payment_reference when is_binary(payment_reference) <-
           Value.reference_string(payment_reference),
         true <- Value.reference?(payment_reference) do
      {:ok,
       %{
         amount: amount,
         billing_scope: :platform,
         currency: currency,
         occurred_at: occurred_at,
         payload: %{
           "provider" => "mercado_pago",
           "authorized_payment_id" => provider_reference,
           "payment_id" => payment_reference,
           "payment_status" => "approved",
           "payment_status_detail" => status_detail,
           "subscription_kind" => "platform"
         },
         platform_subscription_id: platform_subscription_id,
         polo_id: polo_id,
         provider_invoice_reference: provider_reference,
         provider_payment_reference: payment_reference,
         provider_subscription_reference: subscription_reference,
         status: "captured"
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_invoice(
         %Req.Response{
           body: %{
             "id" => response_invoice_reference,
             "preapproval_id" => agreement_reference,
             "external_reference" => external_reference,
             "currency_id" => currency,
             "transaction_amount" => amount,
             "last_modified" => occurred_at,
             "payment" => %{
               "id" => payment_reference,
               "status" => "approved",
               "status_detail" => status_detail
             }
           }
         },
         provider_reference
       )
       when status_detail in ["accredited", "approved"] do
    with ^provider_reference <- Value.reference_string(response_invoice_reference),
         true <- Value.reference?(agreement_reference),
         {:ok, polo_id, order_id} <- Value.external_reference(external_reference),
         true <- Value.currency?(currency),
         {:ok, amount} <- Value.decimal(amount),
         true <- Decimal.positive?(amount),
         {:ok, occurred_at} <- Value.datetime(occurred_at),
         payment_reference when is_binary(payment_reference) <-
           Value.reference_string(payment_reference),
         true <- Value.reference?(payment_reference) do
      {:ok,
       %{
         amount: amount,
         billing_scope: :consumer,
         billing_agreement_reference: agreement_reference,
         currency: currency,
         occurred_at: occurred_at,
         order_id: order_id,
         payload: %{
           "provider" => "mercado_pago",
           "authorized_payment_id" => provider_reference,
           "payment_id" => payment_reference,
           "payment_status" => "approved",
           "payment_status_detail" => status_detail
         },
         polo_id: polo_id,
         provider_invoice_reference: provider_reference,
         provider_payment_reference: payment_reference,
         status: "captured"
       }}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_invoice(%Req.Response{}, _provider_reference),
    do: {:error, :payment_gateway_invalid_response}

  defp subscription_status("pending"), do: {:ok, "pending"}
  defp subscription_status("authorized"), do: {:ok, "active"}
  defp subscription_status(_status), do: :error

  defp subscription_next_action(%{"init_point" => url}, "pending") do
    if Value.redirect_url?(url),
      do: {:ok, %{"type" => "redirect", "url" => url}},
      else: :error
  end

  defp subscription_next_action(_body, "active"), do: {:ok, %{}}
  defp subscription_next_action(_body, _status), do: :error

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: Value.datetime(value)

  defp valid_back_url?(value) do
    uri = URI.parse(value)

    byte_size(value) <= @maximum_back_url_bytes and uri.scheme == "https" and
      is_binary(uri.host) and uri.host != ""
  end
end
