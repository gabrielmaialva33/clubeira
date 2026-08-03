defmodule Clubeira.Catalog.BenefitOfferVersion do
  @moduledoc """
  Immutable commercial content published for a benefit offer.
  """

  use Clubeira.Schema

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "benefit_offer_versions" do
    belongs_to :polo, Polo
    belongs_to :benefit_offer, BenefitOffer

    field :version, :integer
    field :title, :string
    field :description, :string
    field :terms, :string
    field :redemption_instructions, :string
    field :percentage_value, :decimal
    field :amount_value, :decimal
    field :currency, :string
    field :effective_during, TstzRange
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
