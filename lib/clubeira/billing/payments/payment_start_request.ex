defmodule Clubeira.Billing.PaymentStartRequest do
  @moduledoc """
  Validated member request to start paying an existing order.

  Order ownership, amount, currency, provider, and merchant account are always
  derived again inside the tenant transaction.
  """

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @required_fields ~w(order_id payment_method idempotency_key)a

  embedded_schema do
    field :order_id, Ecto.UUID
    field :payment_method, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          order_id: Ecto.UUID.t(),
          payment_method: String.t(),
          idempotency_key: String.t()
        }

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> changeset()
    |> apply_action(:start_payment)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:start_payment)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:payment_method, ["pix"])
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
