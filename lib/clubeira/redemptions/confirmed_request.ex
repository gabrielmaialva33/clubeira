defmodule Clubeira.Redemptions.ConfirmedRequest do
  @moduledoc """
  Validated input for the atomic core of an already authenticated redemption.

  This struct deliberately does not model QR or token verification. A future
  confirmation protocol must authenticate its proof before calling the
  persistence boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @required_fields ~w(
    entitlement_allocation_id
    validation_point_id
    device_installation_id
    idempotency_key
    request_nonce
  )a
  @optional_fields ~w(risk_score request_context)a

  embedded_schema do
    field :entitlement_allocation_id, Ecto.UUID
    field :validation_point_id, Ecto.UUID
    field :device_installation_id, Ecto.UUID
    field :idempotency_key, :string
    field :request_nonce, :string
    field :risk_score, :decimal
    field :request_context, :map, default: %{}
  end

  @type t :: %__MODULE__{
          entitlement_allocation_id: Ecto.UUID.t(),
          validation_point_id: Ecto.UUID.t(),
          device_installation_id: Ecto.UUID.t(),
          idempotency_key: String.t(),
          request_nonce: String.t(),
          risk_score: Decimal.t() | nil,
          request_context: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> validate_length(:request_nonce, min: 16, max: 512)
    |> validate_number(:risk_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_change(:request_context, &validate_json_context/2)
    |> apply_action(:confirm)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:confirm)
  end

  @spec nonce_hash(t()) :: binary()
  def nonce_hash(%__MODULE__{request_nonce: nonce}), do: :crypto.hash(:sha256, nonce)

  defp validate_json_context(field, context) do
    case Jason.encode(context) do
      {:ok, encoded} when byte_size(encoded) <= 16_384 -> []
      {:ok, _encoded} -> [{field, "is too large"}]
      {:error, _reason} -> [{field, "must be valid JSON data"}]
    end
  end
end
