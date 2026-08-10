defmodule Clubeira.Privacy.ConsentEvent do
  @moduledoc """
  Append-only evidence for one consent state transition.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "privacy_consent_events" do
    field :processing_purpose_id, Ecto.UUID
    field :legal_document_version_id, Ecto.UUID
    field :person_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :event_type, :string
    field :occurred_at, :utc_datetime_usec
    field :evidence, :map
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          processing_purpose_id: Ecto.UUID.t(),
          legal_document_version_id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          event_type: String.t(),
          occurred_at: DateTime.t(),
          evidence: map(),
          inserted_at: DateTime.t()
        }

  @doc false
  @spec create_changeset(map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(attributes, %DateTime{} = now) when is_map(attributes) do
    %__MODULE__{}
    |> change(Map.merge(attributes, %{occurred_at: now, inserted_at: now}))
    |> foreign_key_constraint(:processing_purpose_id)
    |> foreign_key_constraint(:legal_document_version_id)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:user_id)
  end
end
