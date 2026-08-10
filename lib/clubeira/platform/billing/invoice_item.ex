defmodule Clubeira.Platform.InvoiceItem do
  @moduledoc "Frozen line item composing one platform invoice."

  use Clubeira.Schema

  alias Clubeira.Platform.Invoice
  alias Clubeira.Polos.Polo

  schema "platform_invoice_items" do
    belongs_to :polo, Polo
    belongs_to :platform_invoice, Invoice

    field :item_kind, :string
    field :description, :string
    field :quantity, :integer
    field :unit_amount, :decimal
    field :total_amount, :decimal
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          platform_invoice_id: Ecto.UUID.t(),
          item_kind: String.t(),
          description: String.t(),
          quantity: pos_integer(),
          unit_amount: Decimal.t(),
          total_amount: Decimal.t(),
          inserted_at: DateTime.t()
        }
end
