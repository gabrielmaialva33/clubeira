defmodule ClubeiraWeb.Auth.EmailVerificationController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.ErrorJSON

  def create(conn, %{"token" => token}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.verify_email(token, context) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :invalid_email_verification} ->
        unprocessable(conn)
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
