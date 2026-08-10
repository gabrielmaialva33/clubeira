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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          purchaser_user_id: Ecto.UUID.t(),
          order_number: String.t(),
          idempotency_key: String.t(),
          currency: String.t(),
          subtotal_amount: Decimal.t(),
          discount_amount: Decimal.t(),
          total_amount: Decimal.t(),
          status: String.t(),
          placed_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
