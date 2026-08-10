defmodule ClubeiraWeb.AccessBootstrapController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias ClubeiraWeb.ErrorJSON

  def show(conn, _params) do
    case Polos.get_actor_access(conn.assigns.current_account_scope) do
      {:ok, access} ->
        render(conn, :show, access: access)

      {:error, reason} ->
        Logger.error("could not load account access bootstrap: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))
    end
  end
end
