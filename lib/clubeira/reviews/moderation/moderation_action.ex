defmodule Clubeira.Reviews.ModerationAction do
  @moduledoc """
  Immutable evidence of one moderator decision.
  """

  use Clubeira.Schema

  schema "moderation_actions" do
    field :review_id, Ecto.UUID
    field :review_report_id, Ecto.UUID
    field :actor_user_id, Ecto.UUID
    field :action, :string
    field :reason, :string
    field :metadata, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          review_id: Ecto.UUID.t(),
          review_report_id: Ecto.UUID.t() | nil,
          actor_user_id: Ecto.UUID.t(),
          action: String.t(),
          reason: String.t(),
          metadata: map(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
