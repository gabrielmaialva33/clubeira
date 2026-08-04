defmodule Clubeira.Billing.SettledPayment do
  @moduledoc """
  Normalized result of a payment capture already authenticated by an adapter.

  This is an internal command, not a webhook payload or a public API contract.
  The adapter must verify the provider proof and remove unnecessary personal or
  secret data before building it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @required_fields ~w(
    order_id
    payment_provider_id
    merchant_account_id
    external_event_id
    provider_reference
    amount
    currency
    occurred_at
  )a
  @optional_fields ~w(payload)a

  embedded_schema do
    field :order_id, Ecto.UUID
    field :payment_provider_id, Ecto.UUID
    field :merchant_account_id, Ecto.UUID
    field :external_event_id, :string
    field :provider_reference, :string
    field :amount, :decimal
    field :currency, :string
    field :occurred_at, :utc_datetime_usec
    field :payload, :map, default: %{}
  end

  @type t :: %__MODULE__{
          order_id: Ecto.UUID.t(),
          payment_provider_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          external_event_id: String.t(),
          provider_reference: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          occurred_at: DateTime.t(),
          payload: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:external_event_id, min: 1, max: 255)
    |> validate_length(:provider_reference, min: 1, max: 255)
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_change(:payload, &validate_json_payload/2)
    |> apply_action(:settle_payment)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:settle_payment)
  end

  defp validate_json_payload(field, payload) do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= 65_536 -> []
      {:ok, _encoded} -> [{field, "is too large"}]
      {:error, _reason} -> [{field, "must be valid JSON data"}]
    end
  end
end
