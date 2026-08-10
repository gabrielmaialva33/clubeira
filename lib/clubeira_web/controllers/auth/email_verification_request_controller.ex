defmodule ClubeiraWeb.Auth.EmailVerificationRequestController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.ErrorJSON

  def create(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    context = RequestContext.new!(conn.assigns.request_id)
    user = conn.assigns.current_account_scope.user

    case Accounts.request_email_verification(user, context) do
      :ok ->
        send_resp(conn, :accepted, "")

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))
    end
  end
end
