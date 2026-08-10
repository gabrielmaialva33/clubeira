defmodule ClubeiraWeb.Auth.SessionJSON do
  @moduledoc false

  def create(%{session: session}) do
    %{
      data: %{
        access_token: session.token,
        token_type: session.token_type,
        expires_at: session.expires_at,
        user: %{
          id: session.user.id,
          email: session.user.email,
          email_verified_at: datetime_to_string(session.user.email_verified_at)
        }
      }
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
