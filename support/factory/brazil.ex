defmodule Clubeira.Factory.Brazil do
  @moduledoc """
  Deterministic generators for valid Brazilian document numbers.

  The returned values are fake test data. They must still go through the same
  encryption and lookup-token boundary used by production identifiers.
  """

  @cpf_base_size 9
  @cpf_sequence_modulus 10_000_000
  @cnpj_root_modulus 90_000_000

  @spec cpf(non_neg_integer()) :: String.t()
  def cpf(sequence) when is_integer(sequence) and sequence >= 0 do
    base = 980_000_000 + rem(sequence, @cpf_sequence_modulus)
    digits = fixed_digits(base, @cpf_base_size)
    first_digit = check_digit(digits, 10..2//-1)
    second_digit = check_digit(digits ++ [first_digit], 11..2//-1)

    digits_to_string(digits ++ [first_digit, second_digit])
  end

  @spec cnpj(non_neg_integer()) :: String.t()
  def cnpj(sequence) when is_integer(sequence) and sequence >= 0 do
    root = 10_000_000 + rem(sequence, @cnpj_root_modulus)
    digits = fixed_digits(root, 8) ++ [0, 0, 0, 1]
    first_digit = check_digit(digits, [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
    second_digit = check_digit(digits ++ [first_digit], [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])

    digits_to_string(digits ++ [first_digit, second_digit])
  end

  defp check_digit(digits, weights) do
    remainder =
      digits
      |> Enum.zip(weights)
      |> Enum.reduce(0, fn {digit, weight}, sum -> sum + digit * weight end)
      |> rem(11)

    if remainder < 2, do: 0, else: 11 - remainder
  end

  defp fixed_digits(number, size) do
    number
    |> Integer.to_string()
    |> String.pad_leading(size, "0")
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)
  end

  defp digits_to_string(digits), do: Enum.join(digits)
end
