defmodule ClubeiraWeb.Member.CheckoutController do
  use ClubeiraWeb, :controller

  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @checkout_fields ~w(product_offering_version_id offering_price_id quantity)
  @unprocessable_checkout_errors ~w(
    actor_required
    actor_unavailable
    benefit_package_unavailable
    entitlement_scope_empty
    invalid_cycle_interval
    offering_unavailable
    polo_policy_unavailable
    polo_unavailable
    subscription_configuration_invalid
    unsupported_activation_policy
    unsupported_cycle_policy
    unsupported_subject_policy
  )a

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, order} <-
           Billing.place_order(
             checkout_scope(conn, route.polo_id),
             checkout_attributes(params, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, order: order)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :idempotency_conflict} ->
        render_error(conn, :conflict)

      {:error, :request_in_progress} ->
        render_error(conn, :conflict)

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :unprocessable_entity)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} when reason in @unprocessable_checkout_errors ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp checkout_scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp checkout_attributes(params, idempotency_key) do
    params
    |> Map.take(@checkout_fields)
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
