defmodule ClubeiraWeb.Auth.BrowserSessionController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.BackofficeAuth
  alias ClubeiraWeb.PartnerAuth
  alias ClubeiraWeb.PlatformAuth

  @session_key "backoffice_session_token"

  def new(conn, _params) do
    render_login(conn, :backoffice, nil, nil)
  end

  def platform_new(conn, _params) do
    render_login(conn, :platform, nil, nil)
  end

  def member_new(conn, _params) do
    render_login(conn, :member, nil, nil)
  end

  def partner_new(conn, _params) do
    render_login(conn, :partner, nil, nil)
  end

  def create(conn, params), do: create_session(conn, params, :backoffice)
  def platform_create(conn, params), do: create_session(conn, params, :platform)
  def member_create(conn, params), do: create_session(conn, params, :member)
  def partner_create(conn, params), do: create_session(conn, params, :partner)

  defp create_session(conn, %{"email" => email, "password" => password}, surface) do
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.login(email, password, context) do
      {:ok, session} -> authorize_login(conn, session, context, surface)
      {:error, :invalid_credentials} -> render_login(conn, surface, email, :invalid_credentials)
      {:error, :rate_limited} -> render_login(conn, surface, email, :rate_limited)
    end
  end

  defp create_session(conn, params, surface) do
    render_login(conn, surface, Map.get(params, "email"), :invalid_credentials)
  end

  def delete(conn, _params), do: logout_browser_session(conn, ~p"/admin/login")
  def platform_delete(conn, _params), do: logout_browser_session(conn, ~p"/platform/login")
  def member_delete(conn, _params), do: logout_browser_session(conn, ~p"/app/login")
  def partner_delete(conn, _params), do: logout_browser_session(conn, "/partner/login")

  defp logout_browser_session(conn, destination) do
    conn
    |> get_session(@session_key)
    |> revoke_session(conn.assigns.request_id)

    conn
    |> configure_session(drop: true)
    |> redirect(to: destination)
  end

  defp authorize_login(conn, session, context, surface) do
    with {:ok, account_scope} <- Accounts.fetch_scope_by_api_token(session.token, context),
         {:ok, destination} <- authorize_destination(surface, account_scope) do
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, session.token)
      |> put_resp_header("cache-control", "private, no-store")
      |> redirect(to: destination)
    else
      _forbidden_or_unavailable ->
        revoke_session(session.token, context.request_id)
        render_login(conn, surface, session.user.email, :forbidden)
    end
  end

  defp authorize_destination(:backoffice, account_scope) do
    with {:ok, _access} <- BackofficeAuth.authorize(account_scope), do: {:ok, ~p"/admin"}
  end

  defp authorize_destination(:platform, account_scope) do
    with {:ok, _access} <- PlatformAuth.authorize(account_scope), do: {:ok, ~p"/platform"}
  end

  defp authorize_destination(:member, _account_scope), do: {:ok, ~p"/app"}

  defp authorize_destination(:partner, account_scope) do
    with {:ok, _access} <- PartnerAuth.authorize(account_scope), do: {:ok, "/partner"}
  end

  defp render_login(conn, surface, email, reason) do
    status = status_for(reason)
    config = login_config(surface)

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:new,
      page_title: config.page_title,
      form: Phoenix.Component.to_form(%{"email" => email || ""}),
      error: error_message(reason, surface),
      login_id: config.login_id,
      login_form_id: config.login_form_id,
      form_action: config.form_action,
      surface_label: config.surface_label,
      form_eyebrow: config.form_eyebrow,
      form_heading: config.form_heading,
      form_description: config.form_description,
      submit_label: config.submit_label
    )
  end

  defp login_config(:backoffice) do
    %{
      login_id: "backoffice-login",
      login_form_id: "backoffice-login-form",
      form_action: ~p"/admin/login",
      page_title: gettext("Backoffice login"),
      surface_label: gettext("Backoffice"),
      form_eyebrow: gettext("Welcome back"),
      form_heading: gettext("Sign in to your operation"),
      form_description: gettext("Use your administrative account to continue."),
      submit_label: gettext("Enter backoffice")
    }
  end

  defp login_config(:platform) do
    %{
      login_id: "platform-login",
      login_form_id: "platform-login-form",
      form_action: ~p"/platform/login",
      page_title: gettext("Platform login"),
      surface_label: gettext("Platform"),
      form_eyebrow: gettext("Global administration"),
      form_heading: gettext("Sign in to the platform"),
      form_description: gettext("Use your global operator account to continue."),
      submit_label: gettext("Enter platform")
    }
  end

  defp login_config(:member) do
    %{
      login_id: "member-login",
      login_form_id: "member-login-form",
      form_action: ~p"/app/login",
      page_title: gettext("Member login"),
      surface_label: gettext("Member app"),
      form_eyebrow: gettext("Your Clubeira"),
      form_heading: gettext("Sign in to your benefits"),
      form_description: gettext("Access your subscriptions, wallet and privacy preferences."),
      submit_label: gettext("Enter Clubeira")
    }
  end

  defp login_config(:partner) do
    %{
      login_id: "partner-login",
      login_form_id: "partner-login-form",
      form_action: "/partner/login",
      page_title: gettext("Partner login"),
      surface_label: gettext("Partner portal"),
      form_eyebrow: gettext("Your operation"),
      form_heading: gettext("Sign in to your places"),
      form_description: gettext("Manage profiles and respond to verified customer reviews."),
      submit_label: gettext("Enter partner portal")
    }
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

  defp error_message(nil, _surface), do: nil

  defp error_message(:invalid_credentials, _surface),
    do: gettext("Check your email and password and try again.")

  defp error_message(:forbidden, :backoffice),
    do: gettext("This account does not have access to the backoffice.")

  defp error_message(:forbidden, :platform),
    do: gettext("This account does not have access to the platform.")

  defp error_message(:forbidden, :member),
    do: gettext("This account is not available for member access.")

  defp error_message(:forbidden, :partner),
    do: gettext("This account does not have current partner access.")

  defp error_message(:rate_limited, _surface),
    do: gettext("Too many attempts. Wait a moment and try again.")
end
