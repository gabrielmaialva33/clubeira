defmodule Clubeira.Subscriptions.BenefitCycle do
  @moduledoc """
  Independent benefit window whose allocations renew without changing billing.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.ProductOfferingPackageAssignment
  alias Clubeira.Types.TstzRange

  schema "benefit_cycles" do
    belongs_to :polo, Polo
    belongs_to :access_contract, AccessContract
    belongs_to :benefit_package_version, BenefitPackageVersion

    belongs_to :offering_package_assignment, ProductOfferingPackageAssignment
    belongs_to :polo_policy_version, PoloPolicyVersion

    field :sequence, :integer
    field :benefits_during, TstzRange
    field :status, :string
    field :delinquency_grace_until, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
