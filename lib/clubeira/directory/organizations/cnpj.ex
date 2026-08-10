defmodule Clubeira.Directory.Cnpj do
  @moduledoc """
  Normalizes and validates numeric and alphanumeric Brazilian CNPJ identifiers.

  The first twelve positions may contain ASCII letters or digits; the final two
  positions remain numeric check digits calculated with modulus 11.
  """

  @first_weights [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
  @second_weights [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
  @mask_characters ~r/[.\-\/\s]/u
  @normalized_pattern ~r/^[A-Z0-9]{12}[0-9]{2}$/
  @reserved_zero_value "00000000000000"

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_cnpj}
  def normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.upcase()
      |> String.replace(@mask_characters, "")

    if valid_normalized?(normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_cnpj}
    end
  end

  def normalize(_value), do: {:error, :invalid_cnpj}

  defp valid_normalized?(normalized) do
    normalized != @reserved_zero_value and Regex.match?(@normalized_pattern, normalized) and
      check_digits_match?(normalized)
  end

  defp check_digits_match?(normalized) do
    <<base::binary-size(12), supplied::binary-size(2)>> = normalized
    first = check_digit(base, @first_weights)
    second = check_digit(base <> Integer.to_string(first), @second_weights)
    supplied == Integer.to_string(first) <> Integer.to_string(second)
  end

  defp check_digit(characters, weights) do
    remainder =
      characters
      |> :binary.bin_to_list()
      |> Enum.zip(weights)
      |> Enum.reduce(0, fn {character, weight}, total ->
        total + (character - ?0) * weight
      end)
      |> rem(11)

    if remainder in [0, 1], do: 0, else: 11 - remainder
  end
end
