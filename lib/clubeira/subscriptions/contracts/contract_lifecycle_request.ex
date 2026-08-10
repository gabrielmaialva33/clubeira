defmodule Clubeira.Subscriptions.ContractLifecycleRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :action, :string
    field :reason, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          action: String.t(),
          reason: String.t(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:action, :reason, :idempotency_key])
    |> update_change(:action, &normalize_action/1)
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required([:action, :reason, :idempotency_key])
    |> validate_inclusion(:action, ~w(suspend reactivate))
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:transition_contract)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:transition_contract)
  end

  defp normalize_action(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_action(value), do: value
  defp normalize_reason(value) when is_binary(value), do: String.trim(value)
  defp normalize_reason(value), do: value
end
