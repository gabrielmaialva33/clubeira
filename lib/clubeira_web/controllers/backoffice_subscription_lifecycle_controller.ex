defmodule ClubeiraWeb.BackofficeSubscriptionLifecycleController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def create(conn, %{"polo_slug" => polo_slug, "contract_id" => contract_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Subscriptions.transition_contract(
             scope(conn, route.polo_id),
             contract_id,
             lifecycle_attributes(params, idempotency_key)
           ) do
      render(conn, :create, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :access_contract_not_found] ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_idempotency_conflict(conn, reason)

      {:error, :invalid_access_contract_transition} ->
        render_error(conn, :conflict, "invalid_access_contract_transition")

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")

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

  defp lifecycle_attributes(params, idempotency_key) do
    params
    |> Map.take(~w(action reason))
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> {:ok, key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp render_idempotency_conflict(conn, :request_in_progress) do
    conn
    |> put_resp_header("retry-after", "1")
    |> render_error(:conflict, "request_in_progress")
  end

  defp render_idempotency_conflict(conn, :idempotency_conflict),
    do: render_error(conn, :conflict, "idempotency_conflict")

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
