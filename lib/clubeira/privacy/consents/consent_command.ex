defmodule Clubeira.Privacy.ConsentCommand do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :state, :string
    field :legal_document_version_id, Ecto.UUID
  end

  @type t :: %__MODULE__{
          state: String.t(),
          legal_document_version_id: Ecto.UUID.t()
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
    |> apply_action(:update)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:update)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:state, :legal_document_version_id])
    |> validate_required([:state, :legal_document_version_id])
    |> validate_inclusion(:state, ~w(granted withdrawn))
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
