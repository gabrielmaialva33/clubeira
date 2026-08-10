defmodule ClubeiraWeb.Member.DeviceKeyJSON do
  @moduledoc false

  def show(%{key: key}) do
    %{
      data: %{
        id: key.id,
        device_installation_id: key.device_installation_id,
        thumbprint: key.thumbprint,
        attestation: key.attestation,
        valid_from: DateTime.to_iso8601(key.valid_from),
        valid_until: datetime_to_string(key.valid_until),
        revoked_at: datetime_to_string(key.revoked_at)
      }
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(datetime), do: DateTime.to_iso8601(datetime)
end
