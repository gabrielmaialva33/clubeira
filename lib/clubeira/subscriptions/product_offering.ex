defmodule Clubeira.Subscriptions.ProductOffering do
  @moduledoc """
  Stable sellable offer for a versioned access product.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.AccessProductVersion

  schema "product_offerings" do
    belongs_to :polo, Polo
    belongs_to :access_product_version, AccessProductVersion

    field :edition_id, Ecto.UUID
    field :code, :string
    field :scope_kind, :string
    field :sales_channel, :string
    field :status, :string
    field :revision, :integer, default: 1

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          access_product_version_id: Ecto.UUID.t(),
          edition_id: Ecto.UUID.t() | nil,
          code: String.t(),
          scope_kind: String.t(),
          sales_channel: String.t(),
          status: String.t(),
          revision: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
