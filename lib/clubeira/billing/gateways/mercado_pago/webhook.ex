defmodule Clubeira.Billing.Gateways.MercadoPago.Webhook do
  @moduledoc false

  alias Clubeira.Billing.Gateways.MercadoPago.Configuration
  alias Clubeira.Billing.MerchantAccount

  @maximum_external_id_bytes 255
  @maximum_signature_bytes 512

  @spec verify(MerchantAccount.t(), map()) :: {:ok, map()} | {:error, atom()}
  def verify(%MerchantAccount{} = account, envelope) when is_map(envelope) do
    with {:ok, data_id} <- data_id(envelope),
         {:ok, event_type, provider_payment_reference} <- classify(envelope, data_id),
         {:ok, request_id} <- single_header(envelope, "x-request-id", @maximum_external_id_bytes),
         {:ok, signature} <- single_header(envelope, "x-signature", @maximum_signature_bytes),
         :ok <- authenticate(account, data_id, request_id, signature) do
      {:ok,
       %{
         kind: event_kind(event_type),
         provider_reference: data_id,
         external_event_id: external_event_id(event_type, data_id, request_id)
       }
       |> maybe_put_payment_reference(provider_payment_reference)}
    else
      {:error, :payment_gateway_not_configured} = error -> error
      {:error, :webhook_unauthorized} = error -> error
      _invalid -> {:error, :invalid_webhook}
    end
  end

  def verify(%MerchantAccount{}, _envelope), do: {:error, :invalid_webhook}

  @spec authenticate(MerchantAccount.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, atom()}
  def authenticate(%MerchantAccount{} = account, data_id, request_id, signature)
      when is_binary(data_id) and is_binary(request_id) and is_binary(signature) do
    with {:ok, secret} <- Configuration.webhook_secret(account.provider_account_reference),
         {:ok, timestamp, supplied_digest} <- signature_parts(signature),
         true <- valid_timestamp?(timestamp),
         expected_digest <- webhook_digest(secret, data_id, request_id, timestamp),
         true <- secure_match?(expected_digest, supplied_digest) do
      :ok
    else
      {:error, :payment_gateway_not_configured} = error -> error
      _invalid -> {:error, :webhook_unauthorized}
    end
  end

  def authenticate(%MerchantAccount{}, _data_id, _request_id, _signature),
    do: {:error, :webhook_unauthorized}

  defp data_id(%{query_params: %{"data.id" => data_id}}) do
    if bounded?(data_id, @maximum_external_id_bytes), do: {:ok, data_id}, else: :error
  end

  defp data_id(_envelope), do: :error

  defp classify(
         %{
           query_params: %{"type" => "order"},
           body_params: %{
             "type" => "order",
             "action" => action,
             "data" => %{"id" => body_data_id}
           }
         },
         data_id
       )
       when is_binary(action) do
    if String.starts_with?(action, "order.") and reference_string(body_data_id) == data_id,
      do: {:ok, "order", nil},
      else: :error
  end

  defp classify(
         %{
           query_params: %{"type" => "subscription_authorized_payment"},
           body_params: %{
             "type" => "subscription_authorized_payment",
             "action" => action,
             "data" => %{"id" => body_data_id}
           }
         },
         data_id
       )
       when is_binary(action) do
    if bounded?(action, @maximum_external_id_bytes) and reference_string(body_data_id) == data_id,
      do: {:ok, "subscription_authorized_payment", nil},
      else: :error
  end

  defp classify(
         %{
           query_params: %{"type" => "topic_chargebacks_wh"},
           body_params: %{
             "type" => "topic_chargebacks_wh",
             "actions" => actions,
             "data" => %{"id" => body_data_id, "payment_id" => payment_reference}
           }
         },
         data_id
       )
       when is_list(actions) do
    if valid_actions?(actions) and reference_string(body_data_id) == data_id and
         bounded?(payment_reference, @maximum_external_id_bytes) do
      {:ok, "topic_chargebacks_wh", payment_reference}
    else
      :error
    end
  end

  defp classify(_envelope, _data_id), do: :error

  defp event_kind("order"), do: :payment
  defp event_kind("subscription_authorized_payment"), do: :recurring_invoice
  defp event_kind("topic_chargebacks_wh"), do: :chargeback

  defp external_event_id("subscription_authorized_payment", data_id, _request_id),
    do: "subscription_authorized_payment:#{data_id}"

  defp external_event_id(_event_type, _data_id, request_id), do: request_id

  defp maybe_put_payment_reference(event, nil), do: event

  defp maybe_put_payment_reference(event, payment_reference),
    do: Map.put(event, :provider_payment_reference, payment_reference)

  defp single_header(%{headers: headers}, name, maximum) when is_map(headers) do
    case Map.get(headers, name) do
      [value] -> if bounded?(value, maximum), do: {:ok, value}, else: :error
      _missing_or_ambiguous -> :error
    end
  end

  defp single_header(_envelope, _name, _maximum), do: :error

  defp valid_actions?(actions) do
    actions != [] and
      Enum.all?(actions, &bounded?(&1, @maximum_external_id_bytes))
  end

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum

  defp reference_string(value) when is_binary(value), do: value
  defp reference_string(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp reference_string(_value), do: nil

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
end
