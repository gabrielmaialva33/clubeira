defmodule ClubeiraWeb.Public.PoloController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias ClubeiraWeb.ErrorJSON

  def index(conn, params) do
    case Polos.list_public(Map.take(params, ~w(after limit))) do
      {:ok, result} ->
        render(conn, :index, polos: result.polos, page: result.page)

      {:error, :invalid_pagination} ->
        conn
        |> put_status(:bad_request)
        |> json(ErrorJSON.render("400.json", %{}))

      {:error, reason} ->
        Logger.error("could not list public polos: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))
    end
  end
end
