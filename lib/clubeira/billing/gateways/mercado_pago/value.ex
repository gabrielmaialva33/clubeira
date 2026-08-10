defmodule Clubeira.Billing.Gateways.MercadoPago.Value do
  @moduledoc false

  @maximum_pix_code_bytes 4_096
  @maximum_redirect_url_bytes 2_048
  @maximum_reference_bytes 255

  @spec currency?(term()) :: boolean()
  def currency?(currency),
    do: is_binary(currency) and String.match?(currency, ~r/^[A-Z]{3}$/)

  @spec datetime(term()) :: {:ok, DateTime.t()} | :error
  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  def datetime(_value), do: :error

  @spec decimal(term()) :: {:ok, Decimal.t()} | :error
  def decimal(%Decimal{} = value), do: {:ok, value}
  def decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  def decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  def decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _invalid -> :error
    end
  end

  def decimal(_value), do: :error

  @spec decimal_string(Decimal.t()) :: String.t()
  def decimal_string(amount),
    do: amount |> Decimal.normalize() |> Decimal.to_string(:normal)

  @spec external_reference(term()) ::
          {:ok, Ecto.UUID.t(), Ecto.UUID.t()} | :error
  def external_reference(value) when is_binary(value) do
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

  def external_reference(_value), do: :error

  @spec platform_external_reference(term()) ::
          {:ok, Ecto.UUID.t(), Ecto.UUID.t()} | :error
  def platform_external_reference(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [polo_id, subscription_id] ->
        with {:ok, polo_id} <- Ecto.UUID.cast(polo_id),
             {:ok, subscription_id} <- Ecto.UUID.cast(subscription_id) do
          {:ok, polo_id, subscription_id}
        end

      _invalid ->
        :error
    end
  end

  def platform_external_reference(_value), do: :error

  @spec pix_code?(term()) :: boolean()
  def pix_code?(value),
    do: is_binary(value) and byte_size(value) in 1..@maximum_pix_code_bytes

  @spec redirect_url?(term()) :: boolean()
  def redirect_url?(value) when is_binary(value) do
    uri = URI.parse(value)

    byte_size(value) <= @maximum_redirect_url_bytes and uri.scheme == "https" and
      mercado_pago_host?(uri.host)
  end

  def redirect_url?(_value), do: false

  @spec reference?(term()) :: boolean()
  def reference?(value),
    do: is_binary(value) and byte_size(value) in 1..@maximum_reference_bytes

  @spec reference_string(term()) :: String.t() | nil
  def reference_string(value) when is_binary(value), do: value
  def reference_string(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  def reference_string(_value), do: nil

  defp mercado_pago_host?("mercadopago.com.br"), do: true

  defp mercado_pago_host?(host) when is_binary(host),
    do: String.ends_with?(host, ".mercadopago.com.br")

  defp mercado_pago_host?(_host), do: false
end
