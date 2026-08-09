defmodule Clubeira.Privacy.ConsentCommand do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :state, :string
    field :legal_document_version_id, Ecto.UUID
  end

  @type t :: %__MODULE__{
          state: String.t(),
          legal_document_version_id: Ecto.UUID.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:state, :legal_document_version_id])
    |> validate_required([:state, :legal_document_version_id])
    |> validate_inclusion(:state, ~w(granted withdrawn))
    |> apply_action(:update)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:update)
  end
end
