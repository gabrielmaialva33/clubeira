defmodule ClubeiraWeb.RegistrationController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias ClubeiraWeb.ErrorJSON

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    context = RequestContext.new!(conn.assigns.request_id)

    case Accounts.register(params, context) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> render(:create, session: session)

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ErrorJSON.render("422.json", %{}))

      {:error, :legal_acceptance_invalid} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ErrorJSON.render("422.json", %{}))

      {:error, :legal_documents_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> put_status(:too_many_requests)
        |> json(ErrorJSON.render("429.json", %{}))
    end
  end
end
