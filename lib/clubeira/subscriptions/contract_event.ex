defmodule Clubeira.Subscriptions.ContractEvent do
  @moduledoc """
  Immutable lifecycle event for one access contract.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.AccessContract

  schema "contract_events" do
    belongs_to :polo, Polo
    belongs_to :access_contract, AccessContract
    belongs_to :actor_user, User

    field :sequence, :integer
    field :event_type, :string
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
