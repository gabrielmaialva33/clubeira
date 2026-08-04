defmodule Clubeira.Subscriptions.EntitlementScopePlace do
  @moduledoc """
  Resolves a shared entitlement scope to participating places in one polo.
  """

  use Ecto.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "entitlement_scope_places" do
    belongs_to :polo, Polo, primary_key: true
    field :entitlement_scope_id, Ecto.UUID, primary_key: true
    belongs_to :polo_place, PoloPlace, primary_key: true

    field :inserted_at, :utc_datetime_usec
  end
end
