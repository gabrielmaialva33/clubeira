defmodule Clubeira.Directory.PlaceParticipationLifecycleRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :action, :string
    field :reason, :string
    field :expected_polo_place_id, :binary_id
    field :expected_revision, :integer
    field :idempotency_key, :string
    field :confirm_retire, :boolean, virtual: true
  end

  @type t :: %__MODULE__{
          action: String.t(),
          reason: String.t(),
          expected_polo_place_id: Ecto.UUID.t(),
          expected_revision: pos_integer(),
          idempotency_key: String.t(),
          confirm_retire: boolean() | nil
        }

  @fields [
    :action,
    :reason,
    :expected_polo_place_id,
    :expected_revision,
    :idempotency_key,
    :confirm_retire
  ]

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
    |> validate_required([
      :action,
      :reason,
      :expected_polo_place_id,
      :expected_revision,
      :idempotency_key
    ])
    |> validate_uuid(:expected_polo_place_id)
    |> validate_inclusion(:action, ~w(suspend reactivate retire))
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_number(:expected_revision, greater_than: 0)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:transition_place_participation)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:transition_place_participation)
  end

  defp normalize_action(value), do: value |> String.trim() |> String.downcase()
  defp normalize_reason(value), do: String.trim(value)

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "is invalid"}]
      end
    end)
  end
end
