defmodule Clubeira.Reviews.ReviewRevision do
  @moduledoc """
  Immutable content snapshot for a review.
  """

  use Clubeira.Schema

  schema "review_revisions" do
    field :review_id, Ecto.UUID
    field :author_user_id, Ecto.UUID
    field :revision_number, :integer
    field :rating, :integer
    field :title, :string
    field :body, :string
    field :edit_reason, :string
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_id: Ecto.UUID.t(),
          author_user_id: Ecto.UUID.t(),
          revision_number: pos_integer(),
          rating: 1..5,
          title: String.t() | nil,
          body: String.t(),
          edit_reason: String.t() | nil,
          inserted_at: DateTime.t()
        }
end
