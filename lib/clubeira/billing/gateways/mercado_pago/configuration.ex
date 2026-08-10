defmodule Clubeira.Billing.Gateways.MercadoPago.Configuration do
  @moduledoc false

  @maximum_account_reference_bytes 255
  @maximum_credential_bytes 4_096
  @invalid_configuration_message """
  MERCADO_PAGO_ACCOUNTS_JSON must be a non-empty JSON object keyed by the \
  merchant account reference, with access_token and webhook_secret strings
  """

  @type account_credentials :: %{
          required(:access_token) => String.t(),
          required(:webhook_secret) => String.t()
        }

  @spec parse_accounts!(String.t()) :: %{required(String.t()) => account_credentials()}
  def parse_accounts!(encoded) when is_binary(encoded) do
    with {:ok, accounts} when is_map(accounts) <- Jason.decode(encoded),
         false <- map_size(accounts) == 0,
         {:ok, parsed} <- parse_accounts(accounts) do
      parsed
    else
      _invalid -> raise ArgumentError, @invalid_configuration_message
    end
  end

  def parse_accounts!(_encoded) do
    raise ArgumentError, @invalid_configuration_message
  end

  @spec webhook_secret(String.t()) ::
          {:ok, String.t()} | {:error, :payment_gateway_not_configured}
  def webhook_secret(account_reference) when is_binary(account_reference) do
    case account_configuration(account_reference) do
      %{webhook_secret: secret} when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, secret}

      %{"webhook_secret" => secret} when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, secret}

      _missing_or_invalid ->
        {:error, :payment_gateway_not_configured}
    end
  end

  defp parse_accounts(accounts) do
    Enum.reduce_while(accounts, {:ok, %{}}, fn
      {reference, credentials}, {:ok, parsed} ->
        case parse_account(reference, credentials) do
          {:ok, account} -> {:cont, {:ok, Map.put(parsed, reference, account)}}
          :error -> {:halt, :error}
        end
    end)
  end

  defp parse_account(
         reference,
         %{"access_token" => access_token, "webhook_secret" => webhook_secret}
       ) do
    if valid_reference?(reference) and valid_credential?(access_token, 16) and
         valid_credential?(webhook_secret, 32) do
      {:ok, %{access_token: access_token, webhook_secret: webhook_secret}}
    else
      :error
    end
  end

  defp parse_account(_reference, _credentials), do: :error

  defp valid_reference?(reference) do
    is_binary(reference) and byte_size(reference) in 1..@maximum_account_reference_bytes and
      String.trim(reference) == reference
  end

  defp valid_credential?(credential, minimum_bytes) do
    is_binary(credential) and byte_size(credential) in minimum_bytes..@maximum_credential_bytes
  end

  defp account_configuration(account_reference) do
    :clubeira
    |> Application.get_env(Clubeira.Billing.Gateways.MercadoPago, [])
    |> Keyword.get(:accounts, %{})
    |> Map.get(account_reference)
  end
end
