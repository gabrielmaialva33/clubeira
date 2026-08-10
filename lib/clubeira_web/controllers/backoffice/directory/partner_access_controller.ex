defmodule ClubeiraWeb.Backoffice.PartnerAccessController do
  use ClubeiraWeb, :controller

  alias Clubeira.Directory
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def create(conn, %{"polo_slug" => polo_slug, "place_id" => place_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Directory.grant_partner_access(
             scope(conn, route.polo_id),
             place_id,
             %{"email" => Map.get(params, "email"), "idempotency_key" => idempotency_key}
           ) do
      conn
      |> put_status(:created)
      |> render(:create, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :place_not_found] ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :partner_user_not_found} ->
        render_error(conn, :unprocessable_entity, "partner_user_not_found")

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :partner_user_has_polo_access,
             :request_in_progress
           ] ->
        render_conflict(conn, reason)

      {:error, reason} when reason in [:invalid_idempotency_key, :partner_role_unavailable] ->
        render_error(conn, :unprocessable_entity)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  def revoke(conn, %{"polo_slug" => polo_slug, "access_id" => access_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Directory.revoke_partner_access(
             scope(conn, route.polo_id),
             access_id,
             %{
               "reason" => Map.get(params, "reason"),
               "idempotency_key" => idempotency_key
             }
           ) do
      conn
      |> put_status(:ok)
      |> render(:revoke, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :partner_access_not_found] ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :partner_access_revoked} ->
        render_error(conn, :conflict, "partner_access_revoked")

      {:error, :partner_access_unavailable} ->
        render_error(conn, :conflict, "partner_access_unavailable")

      {:error, :invalid_idempotency_key} ->
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
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp render_conflict(conn, :request_in_progress) do
    conn
    |> put_resp_header("retry-after", "1")
    |> render_error(:conflict, "request_in_progress")
  end

  defp render_conflict(conn, :idempotency_conflict) do
    render_error(conn, :conflict, "idempotency_conflict")
  end

  defp render_conflict(conn, :partner_user_has_polo_access) do
    render_error(conn, :conflict, "partner_access_conflict")
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end

  defp render_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{code: code}))
  end
end
