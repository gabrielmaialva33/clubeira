defmodule ClubeiraWeb.Backoffice.PlaceProfileForm do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialHour
  alias ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialWindow
  alias ClubeiraWeb.Backoffice.PlaceProfileForm.WeeklyHour

  @primary_key false
  @fields ~w(
    public_email
    public_phone
    category_keys
    expected_polo_place_id
    expected_revision
    idempotency_key
  )a
  @email_pattern ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u

  embedded_schema do
    field :public_email, :string
    field :public_phone, :string
    field :category_keys, {:array, :string}, default: []
    field :expected_polo_place_id, :binary_id
    field :expected_revision, :integer, default: 0
    field :idempotency_key, :string

    embeds_many :weekly_hours, WeeklyHour, on_replace: :delete
    embeds_many :special_hours, SpecialHour, on_replace: :delete
  end

  @type t :: %__MODULE__{
          public_email: String.t() | nil,
          public_phone: String.t() | nil,
          category_keys: [String.t()],
          expected_polo_place_id: Ecto.UUID.t(),
          expected_revision: non_neg_integer(),
          idempotency_key: String.t(),
          weekly_hours: [WeeklyHour.t()],
          special_hours: [SpecialHour.t()]
        }

  @spec from_place(map(), String.t()) :: t()
  def from_place(place, idempotency_key) do
    profile = place.profile

    %__MODULE__{
      public_email: profile && profile.public_email,
      public_phone: profile && profile.public_phone,
      category_keys: category_keys(profile),
      expected_polo_place_id: place.id,
      expected_revision: profile_revision(profile),
      idempotency_key: idempotency_key,
      weekly_hours: weekly_hours(profile),
      special_hours: special_hours(profile)
    }
  end

  @spec change(t(), term()) :: Ecto.Changeset.t()
  def change(profile_form, attributes \\ %{})

  def change(%__MODULE__{} = profile_form, attributes)
      when is_map(attributes) and not is_struct(attributes) do
    profile_form
    |> cast(attributes, @fields)
    |> cast_embed(:weekly_hours,
      with: &WeeklyHour.changeset/2,
      sort_param: :weekly_hours_sort,
      drop_param: :weekly_hours_drop,
      required: true
    )
    |> cast_embed(:special_hours,
      with: &SpecialHour.changeset/2,
      sort_param: :special_hours_sort,
      drop_param: :special_hours_drop
    )
    |> validate_required(@fields)
    |> validate_length(:public_email, min: 3, max: 254)
    |> validate_format(:public_email, @email_pattern)
    |> validate_length(:category_keys, min: 1, max: 8)
    |> validate_length(:weekly_hours, min: 1, max: 28)
    |> validate_length(:special_hours, max: 64)
    |> validate_number(:expected_revision, greater_than_or_equal_to: 0)
  end

  def change(%__MODULE__{} = profile_form, _attributes) do
    profile_form
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec command(Ecto.Changeset.t()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def command(%Ecto.Changeset{} = changeset) do
    case apply_action(changeset, :publish_place_profile) do
      {:ok, profile_form} -> {:ok, command_attributes(profile_form)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec put_domain_errors(Ecto.Changeset.t(), Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def put_domain_errors(form_changeset, domain_changeset) do
    domain_changeset.errors
    |> Enum.reduce(form_changeset, fn {field, error}, changeset ->
      add_error(changeset, form_field(field), elem(error, 0), elem(error, 1))
    end)
    |> Map.put(:action, :publish_place_profile)
  end

  defp command_attributes(profile_form) do
    %{
      contact: %{email: profile_form.public_email, phone: profile_form.public_phone},
      category_keys: profile_form.category_keys,
      weekly_hours: Enum.map(profile_form.weekly_hours, &weekly_attributes/1),
      special_hours: Enum.map(profile_form.special_hours, &special_attributes/1),
      expected_polo_place_id: profile_form.expected_polo_place_id,
      expected_revision: profile_form.expected_revision,
      idempotency_key: profile_form.idempotency_key
    }
  end

  defp weekly_attributes(hour) do
    %{
      weekday: hour.weekday,
      opens_at: format_time(hour.opens_at),
      closes_at: format_time(hour.closes_at)
    }
  end

  defp special_attributes(%SpecialHour{kind: "closed"} = hour) do
    %{date: Date.to_iso8601(hour.local_date), kind: "closed", windows: []}
  end

  defp special_attributes(%SpecialHour{} = hour) do
    %{
      date: Date.to_iso8601(hour.local_date),
      kind: hour.kind,
      windows: Enum.map(hour.windows, &window_attributes/1)
    }
  end

  defp window_attributes(window) do
    %{opens_at: format_time(window.opens_at), closes_at: format_time(window.closes_at)}
  end

  defp format_time(time), do: Time.to_iso8601(time)

  defp category_keys(nil), do: []
  defp category_keys(profile), do: Enum.map(profile.categories, & &1.key)

  defp profile_revision(nil), do: 0
  defp profile_revision(profile), do: profile.revision

  defp weekly_hours(nil),
    do: [%WeeklyHour{weekday: 1, opens_at: ~T[09:00:00], closes_at: ~T[18:00:00]}]

  defp weekly_hours(profile) do
    Enum.map(profile.weekly_hours, fn hour ->
      struct!(WeeklyHour, Map.take(hour, [:weekday, :opens_at, :closes_at]))
    end)
  end

  defp special_hours(nil), do: []

  defp special_hours(profile) do
    Enum.map(profile.special_hours, fn hour ->
      %SpecialHour{
        local_date: hour.date,
        kind: hour.kind,
        windows:
          Enum.map(hour.windows, &struct!(SpecialWindow, Map.take(&1, [:opens_at, :closes_at])))
      }
    end)
  end

  defp form_field(:public_email), do: :public_email
  defp form_field(:public_phone), do: :public_phone
  defp form_field(field), do: field
end
