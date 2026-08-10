defmodule Clubeira.Subscriptions.EntitlementAllocation do
  @moduledoc """
  Exactly-once consumable balance issued for one subject and benefit cycle.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Subscriptions.CycleEntitlementSubject

  schema "entitlement_allocations" do
    belongs_to :polo, Polo
    belongs_to :cycle_entitlement_subject, CycleEntitlementSubject
    belongs_to :polo_place, PoloPlace

    field :benefit_package_item_id, Ecto.UUID
    field :entitlement_scope_id, Ecto.UUID
    field :allocation_kind, :string
    field :issued_units, :integer
    field :available_units, :integer

    timestamps()
  end
end
