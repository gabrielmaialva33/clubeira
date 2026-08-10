defmodule Clubeira.Redemptions.Redemption do
  @moduledoc """
  Immutable successful consumption of an entitlement allocation.
  """

  use Clubeira.Schema

  schema "redemptions" do
    field :polo_id, Ecto.UUID
    field :polo_place_id, Ecto.UUID
    field :entitlement_allocation_id, Ecto.UUID
    field :redemption_attempt_id, Ecto.UUID
    field :validation_point_id, Ecto.UUID
    field :benefit_package_item_id, Ecto.UUID
    field :units, :integer
    field :redeemed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          polo_place_id: Ecto.UUID.t(),
          entitlement_allocation_id: Ecto.UUID.t(),
          redemption_attempt_id: Ecto.UUID.t(),
          validation_point_id: Ecto.UUID.t(),
          benefit_package_item_id: Ecto.UUID.t(),
          units: pos_integer(),
          redeemed_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
