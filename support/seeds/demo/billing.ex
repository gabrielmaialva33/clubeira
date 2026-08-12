defmodule Clubeira.Seeds.Demo.Billing do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @provider_fields ~w(code name status updated_at)a

  @account_fields ~w(
    payment_provider_id
    kind
    name
    provider_account_reference
    status
    updated_at
  )a

  @spec run!() :: map()
  def run! do
    provider =
      Writer.upsert!(
        :payment_provider,
        %{
          id: id(:payment_provider_mercado_pago),
          code: "mercado_pago",
          name: "Mercado Pago",
          status: "active"
        },
        @provider_fields
      )

    consumer_account =
      Writer.upsert!(
        :merchant_account,
        %{
          id: id(:merchant_account_mercado_pago_demo),
          payment_provider: provider,
          kind: "consumer",
          name: "Mercado Pago Demo",
          provider_account_reference: "mercado-pago-demo",
          status: "active"
        },
        @account_fields
      )

    platform_account =
      Writer.upsert!(
        :merchant_account,
        %{
          id: id(:merchant_account_mercado_pago_platform_demo),
          payment_provider: provider,
          kind: "platform",
          name: "Mercado Pago Plataforma Demo",
          provider_account_reference: "mercado-pago-platform-demo",
          status: "active"
        },
        @account_fields
      )

    Enum.each([id(:polo_sobral), id(:polo_londrina)], fn polo_id ->
      Seeds.with_polo!(polo_id, fn ->
        Writer.insert_once!(:polo_merchant_account, %{
          polo: Repo.get!(Polo, polo_id),
          payment_provider: provider,
          merchant_account: consumer_account,
          role: "primary",
          valid_during: Factory.tstz_range(~U[2026-01-01 00:00:00Z])
        })
      end)
    end)

    %{account: consumer_account, platform_account: platform_account, provider: provider}
  end

  defp id(name), do: Ids.fetch!(name)
end
