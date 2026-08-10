defmodule ClubeiraWeb.Public.PlaceController do
  use ClubeiraWeb, :controller

  alias Clubeira.Directory
  alias ClubeiraWeb.ErrorJSON

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    pagination_params = Map.take(params, ["after", "limit"])

    case Directory.fetch_public(polo_slug, pagination_params) do
      {:ok, directory} ->
        render(conn, :index, directory: directory)

      {:error, :invalid_pagination} ->
        conn
        |> put_status(:bad_request)
        |> json(ErrorJSON.render("400.json", %{}))

      {:error, :polo_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ErrorJSON.render("404.json", %{}))
    end
  end
end
