defmodule ClubeiraWeb.Backoffice.OperationsController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Operations
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @outbox_query_fields ~w(after limit status topic)
  @audit_query_fields ~w(action after limit resource_type)

  def retry_outbox_message(
        conn,
        %{"polo_slug" => polo_slug, "message_id" => message_id}
      ) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Operations.retry_outbox_message(
             scope(conn, route.polo_id),
             message_id,
             %{"idempotency_key" => idempotency_key}
           ) do
      conn
      |> put_status(:ok)
      |> render(:retry_outbox_message, result: result)
    else
      {:error, reason} when reason in [:outbox_message_not_found, :polo_not_found] ->
        render_error(conn, :not_found)

      {:error, :operations_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :outbox_message_not_retryable} ->
        render_error(conn, :conflict, "outbox_message_not_retryable")

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")
    end
  end

  def audit_events(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Operations.list_backoffice_audit_events(
             scope(conn, route.polo_id),
             Map.take(params, @audit_query_fields)
           ) do
      render(conn, :audit_events, events: result.events, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :operations_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason} when reason in [:invalid_action, :invalid_resource_type] ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list backoffice audit events: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  def outbox_messages(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Operations.list_backoffice_outbox_messages(
             scope(conn, route.polo_id),
             Map.take(params, @outbox_query_fields)
           ) do
      render(conn, :outbox_messages, messages: result.messages, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :operations_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason} when reason in [:invalid_outbox_status, :invalid_topic] ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list backoffice outbox messages: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
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
