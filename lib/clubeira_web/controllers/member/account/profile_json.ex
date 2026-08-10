defmodule ClubeiraWeb.Member.ProfileJSON do
  @moduledoc false

  def show(%{profile: profile}), do: %{data: data(profile)}
  def update(%{profile: profile}), do: %{data: data(profile)}

  defp data(profile) do
    %{
      id: profile.id,
      display_name: profile.display_name,
      birth_date: date_to_string(profile.birth_date),
      status: profile.status,
      identifiers: Enum.map(profile.identifiers, &identifier_data/1),
      contact_points: Enum.map(profile.contact_points, &contact_data/1)
    }
  end

  defp identifier_data(identifier) do
    %{
      kind: identifier.kind,
      verified_at: datetime_to_string(identifier.verified_at)
    }
  end

  defp contact_data(contact) do
    %{
      kind: contact.kind,
      primary: contact.primary,
      verified_at: datetime_to_string(contact.verified_at)
    }
  end

  defp date_to_string(nil), do: nil
  defp date_to_string(date), do: Date.to_iso8601(date)

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(datetime), do: DateTime.to_iso8601(datetime)
end
