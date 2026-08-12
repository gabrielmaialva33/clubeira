defmodule ClubeiraWeb.Backoffice.PlaceProfileForm.WeeklyHour do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :weekday, :integer
    field :opens_at, :time
    field :closes_at, :time
  end

  @type t :: %__MODULE__{
          weekday: 1..7 | nil,
          opens_at: Time.t() | nil,
          closes_at: Time.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(hour, attributes) do
    hour
    |> cast(attributes, [:weekday, :opens_at, :closes_at])
    |> validate_required([:weekday, :opens_at, :closes_at])
    |> validate_inclusion(:weekday, 1..7)
  end
end
