defmodule Clubeira.Reviews.Review do
  @moduledoc """
  Global review identity whose content history lives in immutable revisions.
  """

  use Clubeira.Schema

  schema "reviews" do
    field :place_id, Ecto.UUID
    field :author_user_id, Ecto.UUID
    field :source_redemption_id, Ecto.UUID
    field :verification_kind, :string
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          place_id: Ecto.UUID.t(),
          author_user_id: Ecto.UUID.t(),
          source_redemption_id: Ecto.UUID.t() | nil,
          verification_kind: String.t(),
          status: String.t(),
          published_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
