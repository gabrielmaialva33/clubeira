defmodule Clubeira.Subscriptions.ProductOfferingPackageAssignment do
  @moduledoc """
  Time-bounded assignment of a benefit package to a commercial offering.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Types.TstzRange

  schema "product_offering_package_assignments" do
    belongs_to :polo, Polo
    belongs_to :product_offering_version, ProductOfferingVersion
    belongs_to :benefit_package_version, BenefitPackageVersion

    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
