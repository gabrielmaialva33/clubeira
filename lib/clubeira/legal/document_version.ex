defmodule Clubeira.Legal.DocumentVersion do
  @moduledoc """
  Immutable published content identity accepted by a user.
  """

  use Clubeira.Schema

  alias Clubeira.Types.TstzRange

  schema "legal_document_versions" do
    field :legal_document_id, Ecto.UUID
    field :version, :integer
    field :locale, :string
    field :content_uri, :string
    field :content_sha256, :binary
    field :effective_during, TstzRange
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          legal_document_id: Ecto.UUID.t(),
          version: pos_integer(),
          locale: String.t(),
          content_uri: String.t(),
          content_sha256: binary(),
          effective_during: Postgrex.Range.t(),
          published_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
