defmodule Clubeira.Redemptions.RedemptionEvent do
  @moduledoc """
  Ordered immutable history for a successful redemption aggregate.
  """

  use Clubeira.Schema

  schema "redemption_events" do
    field :polo_id, Ecto.UUID
    field :redemption_id, Ecto.UUID
    field :sequence, :integer
    field :event_type, :string
    field :actor_user_id, Ecto.UUID
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
