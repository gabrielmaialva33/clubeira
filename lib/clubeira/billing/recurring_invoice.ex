defmodule Clubeira.Billing.RecurringInvoice do
  @moduledoc """
  Normalized recurring charge re-read from an authenticated PSP endpoint.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields ~w(
    billing_agreement_reference provider_invoice_reference provider_payment_reference
    external_event_id polo_id order_id amount currency occurred_at status payload
  )a

  embedded_schema do
    field :billing_agreement_reference, :string
    field :provider_invoice_reference, :string
    field :provider_payment_reference, :string
    field :external_event_id, :string
    field :polo_id, Ecto.UUID
    field :order_id, Ecto.UUID
    field :amount, :decimal
    field :currency, :string
    field :occurred_at, :utc_datetime_usec
    field :status, :string
    field :payload, :map, default: %{}
  end

  @spec new(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:billing_agreement_reference, min: 1, max: 255)
    |> validate_length(:provider_invoice_reference, min: 1, max: 255)
    |> validate_length(:provider_payment_reference, min: 1, max: 255)
    |> validate_length(:external_event_id, min: 1, max: 255)
    |> validate_number(:amount, greater_than: 0)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_inclusion(:status, ["captured"])
    |> validate_change(:payload, &validate_json_payload/2)
    |> apply_action(:reconcile_recurring_invoice)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:reconcile_recurring_invoice)
  end

  defp validate_json_payload(field, payload) do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= 65_536 -> []
      {:ok, _encoded} -> [{field, "is too large"}]
      {:error, _reason} -> [{field, "must be valid JSON data"}]
    end
  end
end
