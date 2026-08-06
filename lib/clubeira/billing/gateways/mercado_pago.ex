defmodule Clubeira.Billing.Gateways.MercadoPago do
  @moduledoc """
  Mercado Pago Orders API adapter.

  Provider payloads terminate here. Callers receive only a normalized payment
  reference and the customer action required to complete a Pix transfer.
  """

  alias Clubeira.Billing.MerchantAccount

  @api_url "https://api.mercadopago.com/v1/orders"
  @pix_expiration "PT30M"
  @maximum_reference_bytes 255
  @maximum_pix_code_bytes 4_096
  @maximum_redirect_url_bytes 2_048

  @type payment_request :: Clubeira.Billing.Gateways.payment_request()
  @type created_payment :: Clubeira.Billing.Gateways.created_payment()
  @type captured_payment :: Clubeira.Billing.Gateways.captured_payment()
  @type terminal_payment :: Clubeira.Billing.Gateways.terminal_payment()
  @type refund_request :: Clubeira.Billing.Gateways.refund_request()
  @type refunded_payment :: Clubeira.Billing.Gateways.refunded_payment()

  @spec create_pix(MerchantAccount.t(), payment_request()) ::
          {:ok, created_payment()} | {:error, atom()}
  def create_pix(%MerchantAccount{} = account, request) when is_map(request) do
    with {:ok, access_token} <- access_token(account.provider_account_reference),
         {:ok, response} <- request_pix_order(access_token, request) do
      normalize_created_pix(response, request.amount)
    end
  end

  @spec refund_order(MerchantAccount.t(), String.t(), refund_request()) ::
          {:ok, refunded_payment()} | {:error, atom()}
  def refund_order(%MerchantAccount{} = account, provider_reference, request)
      when is_binary(provider_reference) and is_map(request) do
    with true <- valid_reference?(provider_reference),
         {:ok, access_token} <- access_token(account.provider_account_reference),
         {:ok, response} <- request_full_refund(access_token, provider_reference, request),
         {:ok, refund} <- normalize_refund(response, provider_reference, request) do
      {:ok, refund}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def refund_order(%MerchantAccount{}, _provider_reference, _request) do
    {:error, :payment_gateway_invalid_response}
  end

  @spec authenticate_webhook(
          MerchantAccount.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | {:error, atom()}
  def authenticate_webhook(%MerchantAccount{} = account, data_id, request_id, signature)
      when is_binary(data_id) and is_binary(request_id) and is_binary(signature) do
    with {:ok, secret} <- webhook_secret(account.provider_account_reference),
         {:ok, timestamp, supplied_digest} <- signature_parts(signature),
         true <- valid_timestamp?(timestamp),
         expected_digest <- webhook_digest(secret, data_id, request_id, timestamp),
         true <- secure_match?(expected_digest, supplied_digest) do
      :ok
    else
      {:error, :payment_gateway_not_configured} = error -> error
      _invalid -> {:error, :invalid_webhook_signature}
    end
  end

  def authenticate_webhook(%MerchantAccount{}, _data_id, _request_id, _signature) do
    {:error, :invalid_webhook_signature}
  end

  @spec fetch_order(MerchantAccount.t(), String.t()) ::
          {:ok,
           :pending
           | {:terminal, terminal_payment()}
           | {:refunded, refunded_payment()}
           | captured_payment()}
          | {:error, atom()}
  def fetch_order(%MerchantAccount{} = account, provider_reference)
      when is_binary(provider_reference) do
    with true <- valid_reference?(provider_reference),
         {:ok, access_token} <- access_token(account.provider_account_reference),
         {:ok, response} <- request_order(access_token, provider_reference),
         {:ok, payment} <- normalize_order(response, provider_reference) do
      {:ok, payment}
    else
      false -> {:error, :payment_gateway_invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def fetch_order(%MerchantAccount{}, _provider_reference) do
    {:error, :payment_gateway_invalid_response}
  end

  defp request_pix_order(access_token, request) do
    options =
      [
        url: @api_url,
        auth: {:bearer, access_token},
        headers: [{"x-idempotency-key", request.idempotency_key}],
        json: %{
          type: "online",
          total_amount: decimal_string(request.amount),
          external_reference: "#{request.polo_id}_#{request.order_id}",
          processing_mode: "automatic",
          payer: %{email: request.payer_email},
          transactions: %{
            payments: [
              %{
                amount: decimal_string(request.amount),
                payment_method: %{id: "pix", type: "bank_transfer"},
                expiration_time: @pix_expiration
              }
            ]
          }
        },
        retry: false,
        receive_timeout: 10_000
      ]
      |> Keyword.merge(request_options())

    case Req.post(options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        {:error, :payment_gateway_unavailable}

      {:ok, %Req.Response{}} ->
        {:error, :payment_gateway_rejected}

      {:error, _reason} ->
        {:error, :payment_gateway_unavailable}
    end
  end

  defp request_order(access_token, provider_reference) do
    options =
      [
        url: @api_url <> "/" <> provider_reference,
        auth: {:bearer, access_token},
        retry: false,
        receive_timeout: 10_000
      ]
      |> Keyword.merge(request_options())

    case Req.get(options) do
      {:ok, %Req.Response{status: 200} = response} ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        {:error, :payment_gateway_unavailable}

      {:ok, %Req.Response{}} ->
        {:error, :payment_gateway_rejected}

      {:error, _reason} ->
        {:error, :payment_gateway_unavailable}
    end
  end

  defp request_full_refund(access_token, provider_reference, request) do
    options =
      [
        url: @api_url <> "/" <> provider_reference <> "/refund",
        auth: {:bearer, access_token},
        headers: [{"x-idempotency-key", request.idempotency_key}],
        json: %{},
        retry: false,
        receive_timeout: 10_000
      ]
      |> Keyword.merge(request_options())

    case Req.post(options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        {:error, :payment_gateway_unavailable}

      {:ok, %Req.Response{}} ->
        {:error, :payment_gateway_rejected}

      {:error, _reason} ->
        {:error, :payment_gateway_unavailable}
    end
  end

  defp normalize_refund(response, provider_reference, request) do
    with {:ok, refund} <- normalize_refund_evidence(response, provider_reference),
         true <- Decimal.equal?(refund.amount, request.amount),
         true <- refund.currency == request.currency,
         true <- refund.polo_id == request.polo_id and refund.order_id == request.order_id,
         true <- refund.provider_payment_reference == request.provider_payment_reference do
      {:ok, refund}
    else
      _invalid -> {:error, :payment_gateway_invalid_response}
    end
  end

  defp normalize_refund_evidence(
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
         {:ok, total_amount} <- decimal(total_amount),
         {:ok, payment_amount} <- decimal(payment_amount),
         {:ok, refund_amount} <- decimal(refund_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- Decimal.equal?(payment_amount, refund_amount),
         true <- Decimal.positive?(refund_amount),
         true <- valid_currency?(currency),
         {:ok, occurred_at} <- datetime(occurred_at),
         {:ok, polo_id, order_id} <- external_reference(external_reference),
         true <- refund_transaction_reference == provider_payment_reference,
         true <- valid_reference?(provider_payment_reference),
         true <- valid_reference?(provider_refund_reference) do
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

  defp normalize_refund_evidence(%Req.Response{}, _provider_reference) do
    {:error, :payment_gateway_invalid_response}
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
    with {:ok, amount} <- decimal(amount),
         true <- Decimal.equal?(amount, expected_amount),
         true <- valid_reference?(provider_reference),
         true <- valid_reference?(provider_payment_reference),
         true <- valid_redirect_url?(redirect_url),
         true <- valid_pix_code?(copy_paste_code) do
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

  defp normalize_created_pix(%Req.Response{}, _expected_amount) do
    {:error, :payment_gateway_invalid_response}
  end

  defp normalize_order(
         %Req.Response{
           body: %{"status" => status, "status_detail" => "refunded"}
         } = response,
         provider_reference
       )
       when status in ["processed", "refunded"] do
    case normalize_refund_evidence(response, provider_reference) do
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
    with {:ok, total_amount} <- decimal(total_amount),
         {:ok, payment_amount} <- decimal(payment_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- valid_currency?(currency),
         {:ok, occurred_at} <- datetime(occurred_at),
         {:ok, polo_id, order_id} <- external_reference(external_reference),
         true <- valid_reference?(provider_payment_reference) do
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
       when status in ["created", "action_required", "processing"] do
    {:ok, :pending}
  end

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
         {:ok, total_amount} <- decimal(total_amount),
         {:ok, payment_amount} <- decimal(payment_amount),
         true <- Decimal.equal?(total_amount, payment_amount),
         true <- valid_currency?(currency),
         {:ok, occurred_at} <- datetime(occurred_at),
         {:ok, polo_id, order_id} <- external_reference(external_reference),
         true <- valid_reference?(provider_payment_reference),
         true <- valid_reference?(status_detail),
         true <- valid_reference?(payment_status_detail) do
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

  defp normalize_order(%Req.Response{}, _provider_reference) do
    {:error, :payment_gateway_invalid_response}
  end

  defp access_token(account_reference) do
    case account_configuration(account_reference) do
      %{access_token: token} when is_binary(token) and byte_size(token) >= 16 -> {:ok, token}
      %{"access_token" => token} when is_binary(token) and byte_size(token) >= 16 -> {:ok, token}
      _missing_or_invalid -> {:error, :payment_gateway_not_configured}
    end
  end

  defp webhook_secret(account_reference) do
    case account_configuration(account_reference) do
      %{webhook_secret: secret} when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, secret}

      %{"webhook_secret" => secret} when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, secret}

      _missing_or_invalid ->
        {:error, :payment_gateway_not_configured}
    end
  end

  defp account_configuration(account_reference) do
    :clubeira
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:accounts, %{})
    |> Map.get(account_reference)
  end

  defp request_options do
    :clubeira
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp decimal(_value), do: :error

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp datetime(_value), do: :error

  defp external_reference(value) when is_binary(value) do
    case String.split(value, "_", parts: 2) do
      [polo_id, order_id] ->
        with {:ok, polo_id} <- Ecto.UUID.cast(polo_id),
             {:ok, order_id} <- Ecto.UUID.cast(order_id) do
          {:ok, polo_id, order_id}
        end

      _invalid ->
        :error
    end
  end

  defp external_reference(_value), do: :error

  defp valid_currency?(currency) do
    is_binary(currency) and String.match?(currency, ~r/^[A-Z]{3}$/)
  end

  defp refunded_status?(status, "refunded") when status in ["processed", "refunded"],
    do: true

  defp refunded_status?(_status, _detail), do: false

  defp terminal_status("expired"), do: {:ok, "expired"}
  defp terminal_status("failed"), do: {:ok, "failed"}
  defp terminal_status(status) when status in ["canceled", "cancelled"], do: {:ok, "cancelled"}
  defp terminal_status(_status), do: :error

  defp valid_reference?(value) do
    is_binary(value) and byte_size(value) in 1..@maximum_reference_bytes
  end

  defp valid_redirect_url?(value) when is_binary(value) do
    uri = URI.parse(value)

    byte_size(value) <= @maximum_redirect_url_bytes and uri.scheme == "https" and
      mercado_pago_host?(uri.host)
  end

  defp valid_redirect_url?(_value), do: false

  defp mercado_pago_host?("mercadopago.com.br"), do: true

  defp mercado_pago_host?(host) when is_binary(host) do
    String.ends_with?(host, ".mercadopago.com.br")
  end

  defp mercado_pago_host?(_host), do: false

  defp valid_pix_code?(value) do
    is_binary(value) and byte_size(value) in 1..@maximum_pix_code_bytes
  end

  defp signature_parts(signature) do
    parts =
      signature
      |> String.split(",", trim: true)
      |> Enum.map(fn part -> String.split(part, "=", parts: 2) end)

    timestamps = for ["ts", value] <- parts, do: String.trim(value)
    digests = for ["v1", value] <- parts, do: String.trim(value)

    case {timestamps, digests} do
      {[timestamp], [digest]} ->
        case Base.decode16(digest, case: :mixed) do
          {:ok, decoded} -> {:ok, timestamp, decoded}
          :error -> {:error, :invalid_webhook_signature}
        end

      _missing_or_ambiguous ->
        {:error, :invalid_webhook_signature}
    end
  end

  defp valid_timestamp?(timestamp) do
    case Integer.parse(timestamp) do
      {_value, ""} -> true
      _invalid -> false
    end
  end

  defp webhook_digest(secret, data_id, request_id, timestamp) do
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"
    :crypto.mac(:hmac, :sha256, secret, manifest)
  end

  defp secure_match?(expected, supplied) when byte_size(expected) == byte_size(supplied) do
    Plug.Crypto.secure_compare(expected, supplied)
  end

  defp secure_match?(_expected, _supplied), do: false

  defp decimal_string(amount), do: amount |> Decimal.normalize() |> Decimal.to_string(:normal)
end
