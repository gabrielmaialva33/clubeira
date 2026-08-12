defmodule ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialHour do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialWindow

  @primary_key false

  embedded_schema do
    field :local_date, :date
    field :kind, :string, default: "closed"

    embeds_many :windows, SpecialWindow, on_replace: :delete
  end

  @type t :: %__MODULE__{
          local_date: Date.t() | nil,
          kind: String.t(),
          windows: [SpecialWindow.t()]
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(hour, attributes) do
    hour
    |> cast(attributes, [:local_date, :kind])
    |> cast_embed(:windows,
      with: &SpecialWindow.changeset/2,
      sort_param: :windows_sort,
      drop_param: :windows_drop
    )
    |> validate_required([:local_date, :kind])
    |> validate_inclusion(:kind, ~w(closed custom))
    |> validate_window_count()
  end

  defp validate_window_count(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :windows, [])} do
      {"closed", []} -> changeset
      {"closed", _windows} -> add_error(changeset, :windows, "must be empty when closed")
      {"custom", []} -> add_error(changeset, :windows, "must not be empty")
      {"custom", windows} when length(windows) <= 8 -> changeset
      {"custom", _windows} -> add_error(changeset, :windows, "has too many entries")
      {_kind, _windows} -> changeset
    end
  end
end
