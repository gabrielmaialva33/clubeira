defmodule Clubeira.People.Phone do
  @moduledoc false

  @spec cast(term()) :: {:ok, String.t()} | :error
  def cast(value) when is_binary(value) do
    value
    |> String.replace(~r/\D/u, "")
    |> normalize_country_code()
  end

  def cast(_value), do: :error

  defp normalize_country_code("55" <> national) when byte_size(national) in [10, 11],
    do: validate_national(national)

  defp normalize_country_code(national) when byte_size(national) in [10, 11],
    do: validate_national(national)

  defp normalize_country_code(_digits), do: :error

  defp validate_national(<<area::binary-size(2), subscriber::binary>>) do
    with true <- valid_area?(area),
         true <- valid_subscriber?(subscriber) do
      {:ok, "+55" <> area <> subscriber}
    else
      false -> :error
    end
  end

  defp valid_area?(<<first, second>>), do: first in ?1..?9 and second in ?0..?9

  defp valid_subscriber?(<<"9", rest::binary-size(8)>>), do: digits?(rest)

  defp valid_subscriber?(<<first, rest::binary-size(7)>>)
       when first in [?2, ?3, ?4, ?5],
       do: digits?(rest)

  defp valid_subscriber?(_subscriber), do: false

  defp digits?(value), do: String.match?(value, ~r/^\d+$/)
end
