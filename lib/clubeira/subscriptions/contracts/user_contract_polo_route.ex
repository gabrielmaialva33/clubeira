defmodule Clubeira.Subscriptions.UserContractPoloRoute do
  @moduledoc """
  Actor-owned routing projection used to locate contracts across tenant cells.

  It contains no contract status or entitlement data and is never an
  authorization decision by itself.
  """

  use Ecto.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Polos.Polo

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "user_contract_polo_routes" do
    belongs_to :user, User, primary_key: true
    belongs_to :polo, Polo, primary_key: true

    field :first_contract_at, :utc_datetime_usec
  end
end
