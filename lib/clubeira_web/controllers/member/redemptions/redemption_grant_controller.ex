defmodule ClubeiraWeb.Member.RedemptionGrantController do
  use ClubeiraWeb, :controller

  alias Clubeira.Redemptions
  alias ClubeiraWeb.ErrorJSON

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    case Redemptions.issue_grant(
           conn.assigns.current_account_scope,
           polo_slug,
           Map.take(params, ~w(entitlement_allocation_id installation_token))
         ) do
      {:ok, grant} ->
        conn
        |> put_status(:created)
        |> render(:create, grant: grant)

      {:error, :polo_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ErrorJSON.render("404.json", %{}))

      {:error, _unavailable_or_invalid} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ErrorJSON.render("422.json", %{}))
    end
  end
end
