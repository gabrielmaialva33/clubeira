defmodule Clubeira.Reviews.ReviewResponse do
  @moduledoc """
  The single public response an operating organization owns for one review.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Directory.Organization
  alias Clubeira.Reviews.Review

  schema "review_responses" do
    belongs_to :review, Review
    belongs_to :organization, Organization
    belongs_to :author_user, User

    field :status, :string
    field :published_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          author_user_id: Ecto.UUID.t(),
          status: String.t(),
          published_at: DateTime.t(),
          removed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
