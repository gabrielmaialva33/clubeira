defmodule ClubeiraWeb.BackofficeValidationPointController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias Clubeira.Redemptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @query_fields ~w(after limit place_id status)

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Redemptions.list_validation_points(
             scope(conn, route.polo_id),
             Map.take(params, @query_fields)
           ) do
      render(conn, :index,
        validation_points: result.validation_points,
        page: result.page
      )
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason}
      when reason in [:invalid_place_id, :invalid_validation_point_status] ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list validation points: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  def create(conn, %{"polo_slug" => polo_slug, "place_id" => place_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Redemptions.provision_validation_point(
             scope(conn, route.polo_id),
             place_id,
             provisioning_attributes(params, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :place_not_found] ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :credential_already_registered} ->
        render_error(conn, :conflict, "validation_credential_conflict")

      {:error, reason} when reason in [:invalid_expiration, :invalid_idempotency_key] ->
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

  defp provisioning_attributes(params, idempotency_key) do
    credential = map_param(params, "credential")

    params
    |> Map.take(~w(name))
    |> Map.merge(Map.take(credential, ~w(secret_sha256 expires_at)))
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp map_param(params, key) do
    case Map.get(params, key) do
      value when is_map(value) -> value
      _invalid -> %{}
    end
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
