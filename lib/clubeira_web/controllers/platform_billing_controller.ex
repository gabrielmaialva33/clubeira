defmodule ClubeiraWeb.PlatformBillingController do
  use ClubeiraWeb, :controller

  alias Clubeira.PlatformBilling
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def show(conn, %{"polo_slug" => polo_slug}) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, billing} <- PlatformBilling.get_billing(scope(conn, route.polo_id)) do
      render(conn, :show, billing: billing)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden, "billing_admin_required")

      {:error, _reason} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
