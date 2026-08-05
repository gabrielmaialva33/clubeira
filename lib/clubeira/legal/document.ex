defmodule Clubeira.Legal.Document do
  @moduledoc """
  Stable identity for a versioned legal document.
  """

  use Clubeira.Schema

  schema "legal_documents" do
    field :code, :string
    field :document_kind, :string
    field :audience, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code: String.t(),
          document_kind: String.t(),
          audience: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
