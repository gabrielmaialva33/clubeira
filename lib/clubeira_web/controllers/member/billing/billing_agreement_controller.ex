defmodule ClubeiraWeb.Member.BillingAgreementController do
  use ClubeiraWeb, :controller

  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @service_errors ~w(payment_gateway_not_configured payment_gateway_unavailable)a
  @bad_gateway_errors ~w(payment_gateway_invalid_response payment_gateway_rejected)a

  def index(conn, %{"polo_slug" => polo_slug}) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, billing} <- Billing.read_account_billing(scope(conn, route.polo_id)) do
      render(conn, :index, billing: billing)
    else
      {:error, :polo_not_found} -> render_error(conn, :not_found)
      {:error, :actor_required} -> render_error(conn, :unprocessable_entity)
    end
  end

  def create(conn, %{"polo_slug" => polo_slug, "order_id" => order_id}) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Billing.start_billing_agreement(scope(conn, route.polo_id), %{
             "order_id" => order_id,
             "idempotency_key" => idempotency_key
           }) do
      conn
      |> put_status(:created)
      |> render(:create, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :order_not_found] ->
        render_error(conn, :not_found)

      {:error, reason}
      when reason in [:idempotency_conflict, :billing_agreement_already_started] ->
        render_error(conn, :conflict)

      {:error, reason} when reason in @service_errors ->
        render_error(conn, :service_unavailable)

      {:error, reason} when reason in @bad_gateway_errors ->
        render_error(conn, :bad_gateway)

      {:error, reason}
      when reason in [
             :actor_required,
             :automatic_renewal_not_enabled,
             :automatic_renewal_unsupported,
             :invalid_idempotency_key,
             :order_not_payable,
             :payment_gateway_unsupported
           ] ->
        render_error(conn, :unprocessable_entity)

      {:error, %Ecto.Changeset{}} ->
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

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> {:ok, key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
