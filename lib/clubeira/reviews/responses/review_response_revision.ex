defmodule Clubeira.Reviews.ReviewResponseRevision do
  @moduledoc """
  Immutable authored content for one organization response revision.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Reviews.ReviewResponse

  schema "review_response_revisions" do
    belongs_to :review_response, ReviewResponse
    belongs_to :author_user, User

    field :revision_number, :integer
    field :body, :string
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_response_id: Ecto.UUID.t(),
          author_user_id: Ecto.UUID.t(),
          revision_number: pos_integer(),
          body: String.t(),
          inserted_at: DateTime.t()
        }
end
