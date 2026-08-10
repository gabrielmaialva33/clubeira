defmodule ClubeiraWeb.Member.AccountJSON do
  @moduledoc false

  def show(%{account_scope: account_scope}) do
    %{
      data: %{
        user: %{
          id: account_scope.user.id,
          email: account_scope.user.email,
          email_verified_at: datetime_to_string(account_scope.user.email_verified_at)
        },
        session: %{
          expires_at: DateTime.to_iso8601(account_scope.session_expires_at)
        }
      }
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
