defmodule ClubeiraWeb.Auth.BrowserSessionController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.BackofficeAuth

  @session_key "backoffice_session_token"

  def new(conn, _params) do
    render_login(conn, nil, nil)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.login(email, password, context) do
      {:ok, session} -> authorize_login(conn, session, context)
      {:error, :invalid_credentials} -> render_login(conn, email, :invalid_credentials)
      {:error, :rate_limited} -> render_login(conn, email, :rate_limited)
    end
  end

  def create(conn, params) do
    render_login(conn, Map.get(params, "email"), :invalid_credentials)
  end

  def delete(conn, _params) do
    conn
    |> get_session(@session_key)
    |> revoke_session(conn.assigns.request_id)

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/admin/login")
  end

  defp authorize_login(conn, session, context) do
    with {:ok, account_scope} <- Accounts.fetch_scope_by_api_token(session.token, context),
         {:ok, _access} <- BackofficeAuth.authorize(account_scope) do
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, session.token)
      |> put_resp_header("cache-control", "private, no-store")
      |> redirect(to: ~p"/admin")
    else
      _forbidden_or_unavailable ->
        revoke_session(session.token, context.request_id)
        render_login(conn, session.user.email, :forbidden)
    end
  end

  defp render_login(conn, email, reason) do
    status = status_for(reason)

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:new,
      page_title: gettext("Backoffice login"),
      form: Phoenix.Component.to_form(%{"email" => email || ""}),
      error: error_message(reason)
    )
  end

  defp revoke_session(token, request_id) when is_binary(token) do
    with {:ok, account_scope} <-
           Accounts.fetch_scope_by_api_token(token, RequestContext.new!(request_id)) do
      Accounts.revoke_session(account_scope)
    end
  end

  defp revoke_session(_token, _request_id), do: :ok

  defp status_for(nil), do: :ok
  defp status_for(:invalid_credentials), do: :unauthorized
  defp status_for(:forbidden), do: :forbidden
  defp status_for(:rate_limited), do: :too_many_requests

  defp error_message(nil), do: nil

  defp error_message(:invalid_credentials),
    do: gettext("Check your email and password and try again.")

  defp error_message(:forbidden),
    do: gettext("This account does not have access to the backoffice.")

  defp error_message(:rate_limited),
    do: gettext("Too many attempts. Wait a moment and try again.")
end
