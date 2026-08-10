defmodule ClubeiraWeb.Backoffice.ValidationPointJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}

  def index(%{validation_points: validation_points, page: page}) do
    %{
      data: Enum.map(validation_points, &validation_point_data/1),
      meta: %{count: length(validation_points), page: page}
    }
  end

  defp validation_point_data(point) do
    %{
      id: point.id,
      polo_place_id: point.polo_place_id,
      name: point.name,
      kind: point.kind,
      status: point.status,
      revision: point.revision,
      recorded_at: DateTime.to_iso8601(point.recorded_at),
      place: point.place,
      credential: credential_data(point.credential)
    }
  end

  defp credential_data(nil), do: nil

  defp credential_data(credential) do
    %{
      id: credential.id,
      version: credential.version,
      kind: credential.kind,
      status: credential.status,
      valid_from: DateTime.to_iso8601(credential.valid_from),
      expires_at: datetime_to_string(credential.expires_at)
    }
  end

  defp datetime_to_string(:unbound), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
