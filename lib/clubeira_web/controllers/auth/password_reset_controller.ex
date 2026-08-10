defmodule ClubeiraWeb.Auth.PasswordResetController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.ErrorJSON

  def create(conn, %{"token" => token, "password" => password}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.reset_password(token, password, context) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, %Ecto.Changeset{}} ->
        unprocessable(conn)

      {:error, :invalid_password_reset} ->
        unprocessable(conn)

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> put_status(:too_many_requests)
        |> json(ErrorJSON.render("429.json", %{}))
    end
  end

  def create(conn, _params) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> unprocessable()
  end

  defp unprocessable(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.render("422.json", %{}))
  end
end
