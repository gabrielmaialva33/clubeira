defmodule Clubeira.Catalog.BenefitOffer do
  @moduledoc """
  Stable identity for a polo-scoped benefit across its published versions.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo

  schema "benefit_offers" do
    belongs_to :polo, Polo

    field :code, :string
    field :name, :string
    field :benefit_kind, :string
    field :status, :string

    timestamps()
  end
end
