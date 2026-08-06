defmodule Clubeira.Directory.PlaceProfileView do
  @moduledoc false

  alias Clubeira.Directory.PoloPlaceProfile

  @spec build(PoloPlaceProfile.t(), [map()], [map()]) :: map()
  def build(%PoloPlaceProfile{} = profile, categories, periods) do
    %{
      "revision" => profile.revision,
      "contact" => %{
        "email" => profile.public_email,
        "phone" => profile.public_phone
      },
      "categories" => category_data(categories),
      "weekly_hours" => weekly_hours(periods),
      "special_hours" => special_hours(periods)
    }
  end

  defp category_data(categories) do
    categories
    |> Enum.sort_by(&{&1.display_order, &1.key})
    |> Enum.map(&%{"key" => &1.key, "name" => &1.name})
  end

  defp weekly_hours(periods) do
    periods
    |> Enum.filter(&(&1.kind == "weekly"))
    |> Enum.sort_by(&{&1.weekday, &1.opens_at, &1.closes_at})
    |> Enum.map(fn period ->
      %{
        "weekday" => period.weekday,
        "opens_at" => Time.to_iso8601(period.opens_at),
        "closes_at" => Time.to_iso8601(period.closes_at),
        "closes_next_day" => period.closes_next_day
      }
    end)
  end

  defp special_hours(periods) do
    periods
    |> Enum.filter(&(&1.kind in ["exception_open", "exception_closed"]))
    |> Enum.group_by(& &1.local_date)
    |> Enum.sort_by(fn {local_date, _periods} -> local_date end)
    |> Enum.map(fn {local_date, date_periods} ->
      if Enum.any?(date_periods, &(&1.kind == "exception_closed")) do
        %{"date" => Date.to_iso8601(local_date), "kind" => "closed", "windows" => []}
      else
        %{
          "date" => Date.to_iso8601(local_date),
          "kind" => "custom",
          "windows" => exception_windows(date_periods)
        }
      end
    end)
  end

  defp exception_windows(periods) do
    periods
    |> Enum.sort_by(&{&1.opens_at, &1.closes_at})
    |> Enum.map(fn period ->
      %{
        "opens_at" => Time.to_iso8601(period.opens_at),
        "closes_at" => Time.to_iso8601(period.closes_at),
        "closes_next_day" => period.closes_next_day
      }
    end)
  end
end
