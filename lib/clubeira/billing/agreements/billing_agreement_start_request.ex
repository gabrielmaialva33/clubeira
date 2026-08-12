defmodule Clubeira.Billing.BillingAgreementStartRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @fields ~w(order_id idempotency_key)a

  embedded_schema do
    field :order_id, Ecto.UUID
    field :idempotency_key, :string
  end

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> changeset()
    |> apply_action(:start_billing_agreement)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:start_billing_agreement)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
