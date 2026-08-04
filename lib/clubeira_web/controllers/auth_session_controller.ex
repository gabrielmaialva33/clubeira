defmodule ClubeiraWeb.AuthSessionController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias ClubeiraWeb.ErrorJSON

  def create(conn, %{"email" => email, "password" => password}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case Accounts.login(email, password) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> render(:create, session: session)

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(ErrorJSON.render("401.json", %{}))
    end
  end

  def create(conn, _params) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.render("422.json", %{}))
  end

  def delete(conn, _params) do
    :ok = Accounts.revoke_session(conn.assigns.current_account_scope)
    send_resp(conn, :no_content, "")
  end
end
