defmodule Clubeira.Directory.PublicPhone do
  @moduledoc false

  @brazilian_local_pattern ~r/^[1-9][0-9](?:[1-9][0-9]{7}|9[0-9]{8})$/
  @input_pattern ~r/^\+?[0-9().\s-]+$/u

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_phone}
  def normalize(value) when is_binary(value) do
    value = String.trim(value)
    digits = String.replace(value, ~r/[^0-9]/, "")

    with true <- Regex.match?(@input_pattern, value),
         :ok <- validate_explicit_country(value),
         {:ok, local_number} <- local_number(digits),
         true <- Regex.match?(@brazilian_local_pattern, local_number) do
      {:ok, "+55#{local_number}"}
    else
      _invalid -> {:error, :invalid_phone}
    end
  end

  def normalize(_value), do: {:error, :invalid_phone}

  defp validate_explicit_country("+" <> _rest = value) do
    if String.starts_with?(value, "+55"), do: :ok, else: {:error, :invalid_phone}
  end

  defp validate_explicit_country(_value), do: :ok

  defp local_number(<<"55", local_number::binary>>) when byte_size(local_number) in [10, 11],
    do: {:ok, local_number}

  defp local_number(local_number) when byte_size(local_number) in [10, 11],
    do: {:ok, local_number}

  defp local_number(_digits), do: {:error, :invalid_phone}
end
