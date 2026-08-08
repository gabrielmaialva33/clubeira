defmodule Clubeira.Reviews.ReviewReport do
  @moduledoc """
  A member report against a published review.

  Free-form details remain restricted to the moderation boundary; public
  responses, audit metadata, domain events and outbox messages use only the
  stable reason code.
  """

  use Clubeira.Schema

  schema "review_reports" do
    field :review_id, Ecto.UUID
    field :reporter_user_id, Ecto.UUID
    field :reason_code, :string
    field :details, :string
    field :status, :string
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_id: Ecto.UUID.t(),
          reporter_user_id: Ecto.UUID.t(),
          reason_code: String.t(),
          details: String.t() | nil,
          status: String.t(),
          inserted_at: DateTime.t()
        }
end
