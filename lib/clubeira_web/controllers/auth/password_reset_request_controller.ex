defmodule ClubeiraWeb.Auth.PasswordResetRequestController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.ErrorJSON

  def create(conn, %{"email" => email}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.request_password_reset(email, context) do
      :ok ->
        send_resp(conn, :accepted, "")

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))
    end
  end

  def create(conn, _params) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_resp(:accepted, "")
  end
end
