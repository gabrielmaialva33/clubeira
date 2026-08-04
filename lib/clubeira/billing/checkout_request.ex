defmodule Clubeira.Billing.CheckoutRequest do
  @moduledoc """
  Validated member choice for a provider-neutral subscription order.

  Price, currency, purchaser, polo, and commercial status are deliberately not
  accepted here. They are derived again inside the tenant transaction.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @required_fields ~w(product_offering_version_id offering_price_id idempotency_key)a
  @optional_fields ~w(quantity)a

  embedded_schema do
    field :product_offering_version_id, Ecto.UUID
    field :offering_price_id, Ecto.UUID
    field :idempotency_key, :string
    field :quantity, :integer, default: 1
  end

  @type t :: %__MODULE__{
          product_offering_version_id: Ecto.UUID.t(),
          offering_price_id: Ecto.UUID.t(),
          idempotency_key: String.t(),
          quantity: 1
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:quantity, equal_to: 1)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:place_order)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:place_order)
  end
end
