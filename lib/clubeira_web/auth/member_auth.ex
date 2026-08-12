defmodule ClubeiraWeb.MemberAuth do
  @moduledoc """
  Authenticates browser sessions for the member application.

  The encrypted cookie stores only the same opaque session token used by the
  API. User status, expiry and revocation are always re-read from PostgreSQL.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  use ClubeiraWeb, :verified_routes
  use Gettext, backend: ClubeiraWeb.Gettext

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext

  @session_key "backoffice_session_token"

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    locale = Map.get(session, "locale", "pt_BR")
    Gettext.put_locale(ClubeiraWeb.Gettext, locale)

    with token when is_binary(token) <- Map.get(session, @session_key),
         {:ok, account_scope} <-
           Accounts.fetch_scope_by_api_token(token, RequestContext.new!()) do
      {:cont,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:locale, locale)}
    else
      _invalid_session ->
        {:halt,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}
    end
  end
end
