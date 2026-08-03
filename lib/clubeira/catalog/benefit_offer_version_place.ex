defmodule Clubeira.Catalog.BenefitOfferVersionPlace do
  @moduledoc """
  Publishes one benefit version at a participating polo place.
  """

  use Clubeira.Schema

  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace

  @primary_key false

  schema "benefit_offer_version_places" do
    belongs_to :polo, Polo, primary_key: true
    belongs_to :benefit_offer_version, BenefitOfferVersion, primary_key: true
    belongs_to :polo_place, PoloPlace, primary_key: true

    field :inserted_at, :utc_datetime_usec
  end
end
