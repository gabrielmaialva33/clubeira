defmodule ClubeiraWeb.BackofficePlaceJSON do
  @moduledoc false

  def index(%{places: places, page: page}) do
    %{
      data: Enum.map(places, &place_data/1),
      meta: %{count: length(places), page: page}
    }
  end

  defp place_data(participation) do
    %Postgrex.Range{lower: starts_at, upper: ends_at} = participation.participation_during

    %{
      polo_place_id: participation.id,
      status: participation.status,
      revision: participation.revision,
      recorded_at: DateTime.to_iso8601(participation.recorded_at),
      participation: %{
        starts_at: DateTime.to_iso8601(starts_at),
        ends_at: range_bound_to_string(ends_at)
      },
      place: participation.place,
      profile: profile_data(participation.profile)
    }
  end

  defp profile_data(nil), do: nil

  defp profile_data(profile) do
    %{
      id: profile.id,
      revision: profile.revision,
      public_email: profile.public_email,
      public_phone: profile.public_phone,
      updated_at: DateTime.to_iso8601(profile.updated_at)
    }
  end

  defp range_bound_to_string(:unbound), do: nil
  defp range_bound_to_string(value), do: DateTime.to_iso8601(value)
end
