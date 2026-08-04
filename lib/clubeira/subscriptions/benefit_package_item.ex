defmodule Clubeira.Subscriptions.BenefitPackageItem do
  @moduledoc """
  Versioned rule connecting a package, offer, scope, and per-cycle allowance.
  """

  use Clubeira.Schema

  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Polos.Polo

  schema "benefit_package_items" do
    belongs_to :polo, Polo
    belongs_to :benefit_offer_version, BenefitOfferVersion

    field :benefit_package_version_id, Ecto.UUID
    field :entitlement_scope_id, Ecto.UUID
    field :allowance_per_cycle, :integer
    field :consumption_unit, :string
    field :subject_policy, :string
    field :stacking_policy, :string
    field :priority, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
