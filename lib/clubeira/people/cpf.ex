defmodule Clubeira.People.Cpf do
  @moduledoc false

  @spec cast(term()) :: {:ok, String.t()} | :error
  def cast(value) when is_binary(value) do
    digits = String.replace(value, ~r/\D/u, "")

    if valid_digits?(digits), do: {:ok, digits}, else: :error
  end

  def cast(_value), do: :error

  defp valid_digits?(<<digit::binary-size(1), rest::binary-size(10)>> = cpf) do
    cpf != String.duplicate(digit, 11) and valid_check_digits?(digit <> rest)
  end

  defp valid_digits?(_cpf), do: false

  defp valid_check_digits?(cpf) do
    digits = for <<digit <- cpf>>, do: digit - ?0
    {body, [first, second]} = Enum.split(digits, 9)

    first == check_digit(body, 10) and
      second == check_digit(body ++ [first], 11)
  end

  defp check_digit(digits, initial_weight) do
    remainder =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, sum ->
        sum + digit * (initial_weight - index)
      end)
      |> rem(11)

    if remainder < 2, do: 0, else: 11 - remainder
  end
end
