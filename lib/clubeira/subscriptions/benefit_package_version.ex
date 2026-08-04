defmodule Clubeira.Subscriptions.BenefitPackageVersion do
  @moduledoc """
  Immutable published snapshot of a benefit package.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.BenefitPackage

  schema "benefit_package_versions" do
    belongs_to :polo, Polo
    belongs_to :benefit_package, BenefitPackage

    field :version, :integer
    field :name, :string
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
