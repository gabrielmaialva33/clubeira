defmodule Clubeira.Subscriptions.EntitlementScope do
  @moduledoc """
  Named set of places across which a package item may consume shared units.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.BenefitPackageVersion

  schema "entitlement_scopes" do
    belongs_to :polo, Polo
    belongs_to :benefit_package_version, BenefitPackageVersion

    field :key, :string
    field :name, :string
    field :scope_kind, :string
    field :inserted_at, :utc_datetime_usec
  end
end
