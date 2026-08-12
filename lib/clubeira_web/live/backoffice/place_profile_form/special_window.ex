defmodule ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialWindow do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :opens_at, :time
    field :closes_at, :time
  end

  @type t :: %__MODULE__{opens_at: Time.t() | nil, closes_at: Time.t() | nil}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(window, attributes) do
    window
    |> cast(attributes, [:opens_at, :closes_at])
    |> validate_required([:opens_at, :closes_at])
  end
end
