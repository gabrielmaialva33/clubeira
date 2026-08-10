defmodule Clubeira.Directory.PlaceProfileUpdateRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Directory.PublicPhone

  @primary_key false
  @fields ~w(
    public_email
    public_phone
    category_keys
    weekly_hours
    special_hours
    idempotency_key
  )a
  @category_key_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @email_pattern ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u
  @atom_keys %{
    "category_keys" => :category_keys,
    "closes_at" => :closes_at,
    "contact" => :contact,
    "date" => :date,
    "email" => :email,
    "idempotency_key" => :idempotency_key,
    "kind" => :kind,
    "opens_at" => :opens_at,
    "phone" => :phone,
    "special_hours" => :special_hours,
    "weekday" => :weekday,
    "weekly_hours" => :weekly_hours,
    "windows" => :windows
  }

  embedded_schema do
    field :public_email, :string
    field :public_phone, :string
    field :category_keys, {:array, :string}
    field :weekly_hours, {:array, :map}
    field :special_hours, {:array, :map}
    field :idempotency_key, :string
  end

  @type opening_window :: %{
          optional(:weekday) => 1..7,
          required(:opens_at) => Time.t(),
          required(:closes_at) => Time.t(),
          required(:closes_next_day) => boolean()
        }

  @type special_hours :: %{
          local_date: Date.t(),
          kind: String.t(),
          windows: [opening_window()]
        }

  @type t :: %__MODULE__{
          public_email: String.t(),
          public_phone: String.t(),
          category_keys: [String.t()],
          weekly_hours: [opening_window()],
          special_hours: [special_hours()],
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    changeset =
      %__MODULE__{}
      |> cast(flatten(attributes), @fields)
      |> normalize_email()
      |> normalize_phone()
      |> normalize_category_keys()
      |> normalize_weekly_hours()
      |> normalize_special_hours()
      |> validate_required(@fields)
      |> validate_length(:public_email, min: 3, max: 254)
      |> validate_format(:public_email, @email_pattern)
      |> validate_length(:category_keys, min: 1, max: 8)
      |> validate_length(:weekly_hours, min: 1, max: 28)
      |> validate_length(:special_hours, max: 64)
      |> validate_length(:idempotency_key, min: 8, max: 128)
      |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)

    apply_action(changeset, :update)
  end

  def new(_attributes), do: new(%{})

  defp flatten(attributes) do
    contact = child_map(attributes, "contact")

    %{
      public_email: value(contact, "email"),
      public_phone: value(contact, "phone"),
      category_keys: value(attributes, "category_keys"),
      weekly_hours: value(attributes, "weekly_hours"),
      special_hours: value_or_default(attributes, "special_hours", []),
      idempotency_key: value(attributes, "idempotency_key")
    }
  end

  defp normalize_email(changeset) do
    update_change(changeset, :public_email, fn email ->
      email |> String.trim() |> String.downcase()
    end)
  end

  defp normalize_phone(changeset) do
    case fetch_change(changeset, :public_phone) do
      {:ok, phone} ->
        case PublicPhone.normalize(phone) do
          {:ok, normalized} -> put_change(changeset, :public_phone, normalized)
          {:error, :invalid_phone} -> add_error(changeset, :public_phone, "is invalid")
        end

      :error ->
        changeset
    end
  end

  defp normalize_category_keys(changeset) do
    case fetch_change(changeset, :category_keys) do
      {:ok, category_keys} ->
        normalized = Enum.map(category_keys, &normalize_key/1)

        cond do
          Enum.any?(normalized, &(not Regex.match?(@category_key_pattern, &1))) ->
            add_error(changeset, :category_keys, "contains an invalid key")

          length(normalized) != MapSet.size(MapSet.new(normalized)) ->
            add_error(changeset, :category_keys, "contains duplicate keys")

          true ->
            put_change(changeset, :category_keys, Enum.sort(normalized))
        end

      :error ->
        changeset
    end
  end

  defp normalize_weekly_hours(changeset) do
    case fetch_change(changeset, :weekly_hours) do
      {:ok, weekly_hours} ->
        with {:ok, normalized} <- map_all(weekly_hours, &normalize_weekly_window/1),
             false <- overlapping_weekly_windows?(normalized) do
          put_change(
            changeset,
            :weekly_hours,
            Enum.sort_by(normalized, &{&1.weekday, &1.opens_at, &1.closes_at})
          )
        else
          _invalid ->
            add_error(changeset, :weekly_hours, "contains invalid or overlapping windows")
        end

      :error ->
        changeset
    end
  end

  defp normalize_special_hours(changeset) do
    case fetch_change(changeset, :special_hours) do
      {:ok, special_hours} ->
        with {:ok, normalized} <- map_all(special_hours, &normalize_special_day/1),
             true <- unique_special_dates?(normalized),
             false <- overlapping_special_hours?(normalized) do
          put_change(changeset, :special_hours, Enum.sort_by(normalized, & &1.local_date))
        else
          _invalid ->
            add_error(
              changeset,
              :special_hours,
              "contains invalid, duplicate or overlapping dates"
            )
        end

      :error ->
        changeset
    end
  end

  defp normalize_weekly_window(window) when is_map(window) do
    with weekday when weekday in 1..7 <- value(window, "weekday"),
         {:ok, normalized} <- normalize_window(window) do
      {:ok, Map.put(normalized, :weekday, weekday)}
    else
      _invalid -> :error
    end
  end

  defp normalize_weekly_window(_window), do: :error

  defp normalize_special_day(day) when is_map(day) do
    with {:ok, local_date} <- parse_date(value(day, "date")),
         kind when kind in ["closed", "custom"] <- normalize_kind(value(day, "kind")),
         {:ok, windows} <- normalize_special_windows(kind, value(day, "windows")) do
      {:ok, %{local_date: local_date, kind: kind, windows: windows}}
    else
      _invalid -> :error
    end
  end

  defp normalize_special_day(_day), do: :error

  defp normalize_special_windows("closed", windows) when windows in [nil, []], do: {:ok, []}

  defp normalize_special_windows("custom", windows) when is_list(windows) do
    with true <- windows != [] and length(windows) <= 8,
         {:ok, normalized} <- map_all(windows, &normalize_window/1),
         false <- overlapping_linear_windows?(normalized) do
      {:ok, Enum.sort_by(normalized, &{&1.opens_at, &1.closes_at})}
    else
      _invalid -> :error
    end
  end

  defp normalize_special_windows(_kind, _windows), do: :error

  defp normalize_window(window) when is_map(window) do
    with {:ok, opens_at} <- parse_time(value(window, "opens_at")),
         {:ok, closes_at} <- parse_time(value(window, "closes_at")) do
      {:ok,
       %{
         opens_at: opens_at,
         closes_at: closes_at,
         closes_next_day: Time.compare(closes_at, opens_at) != :gt
       }}
    else
      _invalid -> :error
    end
  end

  defp normalize_window(_window), do: :error

  defp parse_time(value) when is_binary(value) do
    candidate = if Regex.match?(~r/^\d{2}:\d{2}$/, value), do: value <> ":00", else: value

    case Time.from_iso8601(candidate) do
      {:ok, time} -> {:ok, Time.truncate(time, :second)}
      {:error, _reason} -> :error
    end
  end

  defp parse_time(_value), do: :error

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp overlapping_weekly_windows?(windows) do
    windows
    |> intervals(&weekly_interval/1)
    |> overlapping_cyclic_intervals?()
  end

  defp overlapping_linear_windows?(windows) do
    windows
    |> intervals(&linear_interval/1)
    |> overlapping_intervals?()
  end

  defp overlapping_special_hours?(days) do
    days
    |> Enum.flat_map(&special_day_intervals/1)
    |> overlapping_intervals?()
  end

  defp intervals(values, mapper), do: Enum.map(values, mapper)

  defp weekly_interval(window) do
    day_start = (window.weekday - 1) * 1_440
    start_minute = day_start + minute_of_day(window.opens_at)
    end_minute = day_start + minute_of_day(window.closes_at)
    {start_minute, end_minute + if(window.closes_next_day, do: 1_440, else: 0)}
  end

  defp linear_interval(window) do
    start_minute = minute_of_day(window.opens_at)
    end_minute = minute_of_day(window.closes_at)
    {start_minute, end_minute + if(window.closes_next_day, do: 1_440, else: 0)}
  end

  defp special_day_intervals(%{kind: "closed", local_date: local_date}) do
    day_start = Date.to_gregorian_days(local_date) * 1_440
    [{day_start, day_start + 1_440}]
  end

  defp special_day_intervals(%{kind: "custom", local_date: local_date, windows: windows}) do
    day_start = Date.to_gregorian_days(local_date) * 1_440

    Enum.map(windows, fn window ->
      {start_minute, end_minute} = linear_interval(window)
      {day_start + start_minute, day_start + end_minute}
    end)
  end

  defp overlapping_cyclic_intervals?(intervals) do
    pair_overlaps?(intervals, fn first, second ->
      overlap?(first, second) or
        overlap?(shift(first, 10_080), second) or
        overlap?(first, shift(second, 10_080))
    end)
  end

  defp overlapping_intervals?(intervals), do: pair_overlaps?(intervals, &overlap?/2)

  defp pair_overlaps?(intervals, overlap) do
    intervals
    |> Enum.with_index()
    |> Enum.any?(fn {first, index} ->
      intervals
      |> Enum.drop(index + 1)
      |> Enum.any?(&overlap.(first, &1))
    end)
  end

  defp overlap?({first_start, first_end}, {second_start, second_end}) do
    first_start < second_end and second_start < first_end
  end

  defp shift({start_minute, end_minute}, offset),
    do: {start_minute + offset, end_minute + offset}

  defp minute_of_day(time), do: time.hour * 60 + time.minute

  defp unique_special_dates?(days) do
    dates = Enum.map(days, & &1.local_date)
    length(dates) == MapSet.size(MapSet.new(dates))
  end

  defp map_all(values, mapper) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case mapper.(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp map_all(_values, _mapper), do: :error

  defp normalize_key(key), do: key |> String.trim() |> String.downcase()
  defp normalize_kind(kind) when is_binary(kind), do: kind |> String.trim() |> String.downcase()
  defp normalize_kind(_kind), do: nil

  defp child_map(map, key) do
    case value(map, key) do
      child when is_map(child) -> child
      _invalid -> %{}
    end
  end

  defp value(map, key) when is_map(map) do
    case fetch_value(map, key) do
      {:ok, found} -> found
      :error -> nil
    end
  end

  defp value_or_default(map, key, default) do
    case fetch_value(map, key) do
      {:ok, found} -> found
      :error -> default
    end
  end

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, found} -> {:ok, found}
      :error -> Map.fetch(map, Map.fetch!(@atom_keys, key))
    end
  end
end
