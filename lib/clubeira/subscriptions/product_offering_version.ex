defmodule Clubeira.Subscriptions.ProductOfferingVersion do
  @moduledoc """
  Immutable commercial terms captured by an access contract.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Types.TstzRange

  schema "product_offering_versions" do
    belongs_to :polo, Polo
    belongs_to :product_offering, ProductOffering

    field :version, :integer
    field :name, :string
    field :description, :string
    field :effective_during, TstzRange
    field :activation_policy, :string
    field :cycle_policy, :string
    field :cycle_interval_unit, :string
    field :cycle_interval_count, :integer
    field :renewal_policy, :string
    field :minimum_beneficiaries, :integer
    field :maximum_beneficiaries, :integer
    field :delinquency_grace_days_override, :integer
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
