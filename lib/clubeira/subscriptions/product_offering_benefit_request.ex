defmodule Clubeira.Subscriptions.ProductOfferingBenefitRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields ~w(benefit_offer_version_id allowance_per_cycle consumption_unit)a

  embedded_schema do
    field :benefit_offer_version_id, Ecto.UUID
    field :allowance_per_cycle, :integer
    field :consumption_unit, :string
  end

  @type t :: %__MODULE__{
          benefit_offer_version_id: Ecto.UUID.t(),
          allowance_per_cycle: pos_integer(),
          consumption_unit: String.t()
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(request, attributes) do
    request
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_number(:allowance_per_cycle, greater_than: 0, less_than: 32_768)
    |> validate_inclusion(:consumption_unit, ~w(per_place shared_scope))
  end
end
