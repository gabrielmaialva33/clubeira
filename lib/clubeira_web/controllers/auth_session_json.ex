defmodule ClubeiraWeb.AuthSessionJSON do
  @moduledoc false

  def create(%{session: session}) do
    %{
      data: %{
        access_token: session.token,
        token_type: session.token_type,
        expires_at: session.expires_at,
        user: %{
          id: session.user.id,
          email: session.user.email
        }
      }
    }
  end
end
