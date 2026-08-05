defmodule ClubeiraWeb.LegalController do
  use ClubeiraWeb, :controller

  alias Clubeira.Legal
  alias ClubeiraWeb.ErrorJSON

  def registration(conn, params) do
    case Legal.list_registration_documents(params) do
      {:ok, documents} ->
        render(conn, :registration, documents: documents)

      {:error, :invalid_locale} ->
        conn
        |> put_status(:bad_request)
        |> json(ErrorJSON.render("400.json", %{}))
    end
  end
end
