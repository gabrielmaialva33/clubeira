defmodule ClubeiraWeb.Member.WalletJSON do
  @moduledoc false

  def index(%{wallet: wallet}) do
    %{
      data: %{
        polo: wallet.polo,
        vouchers: Enum.map(wallet.vouchers, &voucher_data/1)
      },
      meta: %{count: length(wallet.vouchers)}
    }
  end

  defp voucher_data(voucher) do
    update_in(voucher, [:offer], fn offer ->
      offer
      |> Map.update!(:percentage_value, &decimal_to_string/1)
      |> Map.update!(:amount_value, &decimal_to_string/1)
    end)
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)
end
