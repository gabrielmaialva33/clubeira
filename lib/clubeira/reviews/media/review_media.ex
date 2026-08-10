defmodule Clubeira.Reviews.ReviewMedia do
  @moduledoc """
  Trusted storage metadata attached to one immutable review revision.
  """

  use Clubeira.Schema

  alias Clubeira.Reviews.ReviewRevision

  schema "review_media" do
    belongs_to :review_revision, ReviewRevision

    field :kind, :string
    field :storage_key, :string, redact: true
    field :content_type, :string
    field :content_sha256, :binary, redact: true
    field :position, :integer
    field :width, :integer
    field :height, :integer
    field :duration_ms, :integer
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_revision_id: Ecto.UUID.t(),
          kind: String.t(),
          storage_key: String.t(),
          content_type: String.t(),
          content_sha256: binary(),
          position: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration_ms: pos_integer() | nil,
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
