defmodule Clubeira.Billing.RefundRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :reason, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          reason: String.t(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:reason, :idempotency_key])
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required([:reason, :idempotency_key])
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:refund_payment)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:refund_payment)
  end

  defp normalize_reason(value) when is_binary(value), do: String.trim(value)
  defp normalize_reason(value), do: value
end
