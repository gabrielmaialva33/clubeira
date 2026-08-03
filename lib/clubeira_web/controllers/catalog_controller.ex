defmodule ClubeiraWeb.CatalogController do
  use ClubeiraWeb, :controller

  alias Clubeira.Catalog
  alias ClubeiraWeb.ErrorJSON

  def show(conn, %{"polo_slug" => polo_slug} = params) do
    pagination_params = Map.take(params, ["after", "limit"])

    case Catalog.fetch_public(polo_slug, pagination_params) do
      {:ok, catalog} ->
        render(conn, :show, catalog: catalog)

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
