defmodule ClubeiraWeb.Platform.SubscriptionController do
  use ClubeiraWeb, :controller

  alias Clubeira.PlatformBilling
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @service_errors ~w(payment_gateway_not_configured payment_gateway_unavailable)a
  @gateway_errors ~w(payment_gateway_invalid_response payment_gateway_rejected)a

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           PlatformBilling.start_subscription(
             scope(conn, route.polo_id),
             Map.take(params, ~w(platform_price_id idempotency_key))
           ) do
      render(conn, :create, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :platform_price_not_found] ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden, "billing_admin_required")

      {:error, reason}
      when reason in [:idempotency_conflict, :platform_subscription_already_active] ->
        render_error(conn, :conflict, Atom.to_string(reason))

      {:error, reason} when reason in @service_errors ->
        render_error(conn, :service_unavailable)

      {:error, reason} when reason in @gateway_errors ->
        render_error(conn, :bad_gateway)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        render_error(conn, :unprocessable_entity, Atom.to_string(reason))
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
