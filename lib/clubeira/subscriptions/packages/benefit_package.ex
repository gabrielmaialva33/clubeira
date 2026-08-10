defmodule Clubeira.Subscriptions.BenefitPackage do
  @moduledoc """
  Stable identity of a reusable package of voucher definitions.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo

  schema "benefit_packages" do
    belongs_to :polo, Polo

    field :code, :string
    field :name, :string
    field :status, :string

    timestamps()
  end
end
