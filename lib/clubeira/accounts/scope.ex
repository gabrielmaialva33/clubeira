defmodule Clubeira.Accounts.Scope do
  @moduledoc """
  Authenticated account and API session attached to the current request.
  """

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession

  @enforce_keys [:user, :session_id, :session_expires_at, :request_id]
  defstruct [:user, :session_id, :session_expires_at, :request_id]

  @type t :: %__MODULE__{
          user: User.t(),
          session_id: Ecto.UUID.t(),
          session_expires_at: DateTime.t(),
          request_id: Ecto.UUID.t()
        }

  @spec for_session(User.t(), UserSession.t()) :: t()
  def for_session(%User{} = user, %UserSession{} = session) do
    for_session(user, session, RequestContext.new!())
  end

  @spec for_session(User.t(), UserSession.t(), RequestContext.t()) :: t()
  def for_session(
        %User{} = user,
        %UserSession{} = session,
        %RequestContext{} = context
      ) do
    %__MODULE__{
      user: user,
      session_id: session.id,
      session_expires_at: session.expires_at,
      request_id: context.request_id
    }
  end
end
