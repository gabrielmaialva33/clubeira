defmodule Clubeira.Subscriptions.Order do
  @moduledoc """
  Commercial purchase that originates an independent access contract.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Polos.Polo

  schema "orders" do
    belongs_to :polo, Polo
    belongs_to :purchaser_user, User

    field :order_number, :string
    field :idempotency_key, :string
    field :currency, :string
    field :subtotal_amount, :decimal
    field :discount_amount, :decimal
    field :total_amount, :decimal
    field :status, :string
    field :placed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    timestamps()
  end
end
