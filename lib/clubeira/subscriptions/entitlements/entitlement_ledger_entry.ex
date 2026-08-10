defmodule Clubeira.Subscriptions.EntitlementLedgerEntry do
  @moduledoc """
  Append-only balance movement for one entitlement allocation.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Subscriptions.EntitlementAllocation

  schema "entitlement_ledger_entries" do
    belongs_to :polo, Polo
    belongs_to :entitlement_allocation, EntitlementAllocation
    belongs_to :redemption, Redemption

    field :entry_kind, :string
    field :delta_units, :integer
    field :idempotency_key, :string
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          entitlement_allocation_id: Ecto.UUID.t(),
          redemption_id: Ecto.UUID.t() | nil,
          entry_kind: String.t(),
          delta_units: integer(),
          idempotency_key: String.t(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
