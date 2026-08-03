defmodule Clubeira.Redemptions.RedemptionAttempt do
  @moduledoc """
  Immutable accepted or denied attempt used for fraud analysis and replay defense.
  """

  use Clubeira.Schema

  schema "redemption_attempts" do
    field :polo_id, Ecto.UUID
    field :polo_place_id, Ecto.UUID
    field :validation_point_id, Ecto.UUID
    field :entitlement_allocation_id, Ecto.UUID
    field :benefit_package_item_id, Ecto.UUID
    field :requesting_user_id, Ecto.UUID
    field :device_installation_id, Ecto.UUID
    field :operator_user_id, Ecto.UUID
    field :idempotency_key, :string
    field :decision, :string
    field :reason_code, :string
    field :request_nonce_hash, :binary
    field :risk_score, :decimal
    field :request_context, :map
    field :requested_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          polo_place_id: Ecto.UUID.t(),
          validation_point_id: Ecto.UUID.t(),
          entitlement_allocation_id: Ecto.UUID.t(),
          benefit_package_item_id: Ecto.UUID.t(),
          requesting_user_id: Ecto.UUID.t(),
          device_installation_id: Ecto.UUID.t(),
          operator_user_id: Ecto.UUID.t() | nil,
          idempotency_key: String.t(),
          decision: String.t(),
          reason_code: String.t() | nil,
          request_nonce_hash: binary(),
          risk_score: Decimal.t() | nil,
          request_context: map(),
          requested_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
