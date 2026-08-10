defmodule Clubeira.Billing.BillingAgreementStartRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields ~w(order_id idempotency_key)a

  embedded_schema do
    field :order_id, Ecto.UUID
    field :idempotency_key, :string
  end

  @spec new(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:start_billing_agreement)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:start_billing_agreement)
  end
end
