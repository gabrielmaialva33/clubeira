defmodule Clubeira.Redemptions.ValidationPointLifecycleRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @actions ~w(suspend reactivate retire)
  @fields [:action, :reason, :idempotency_key]

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

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    cast(%__MODULE__{}, attributes, @fields)
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> change()
    |> update_change(:action, &normalize_action/1)
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required([:action, :reason, :idempotency_key])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:transition_validation_point)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:transition_validation_point)
  end

  defp normalize_action(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_action(value), do: value

  defp normalize_reason(value) when is_binary(value), do: String.trim(value)
  defp normalize_reason(value), do: value
end
