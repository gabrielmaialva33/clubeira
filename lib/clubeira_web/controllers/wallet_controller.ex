defmodule ClubeiraWeb.WalletController do
  use ClubeiraWeb, :controller

  alias Clubeira.Subscriptions
  alias ClubeiraWeb.ErrorJSON

  def index(conn, %{"polo_slug" => polo_slug}) do
    case Subscriptions.list_wallet(conn.assigns.current_account_scope, polo_slug) do
      {:ok, wallet} ->
        render(conn, :index, wallet: wallet)

      {:error, :polo_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ErrorJSON.render("404.json", %{}))
    end
  end
end
