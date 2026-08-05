defmodule Clubeira.Legal.Acceptance do
  @moduledoc """
  Immutable evidence that a user accepted one exact legal document version.
  """

  use Clubeira.Schema

  schema "legal_acceptances" do
    field :legal_document_version_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :person_id, Ecto.UUID
    field :polo_id, Ecto.UUID
    field :device_installation_id, Ecto.UUID
    field :accepted_at, :utc_datetime_usec
    field :user_agent, :string
    field :evidence, :map
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          legal_document_version_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t() | nil,
          polo_id: Ecto.UUID.t() | nil,
          device_installation_id: Ecto.UUID.t() | nil,
          accepted_at: DateTime.t(),
          user_agent: String.t() | nil,
          evidence: map(),
          inserted_at: DateTime.t()
        }
end
