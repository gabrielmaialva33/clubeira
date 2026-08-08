defmodule ClubeiraWeb.ReviewReportController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def create(
        conn,
        %{"polo_slug" => polo_slug, "place_id" => place_id, "review_id" => review_id} = params
      ) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, report} <-
           Reviews.report(
             scope(conn, route.polo_id),
             report_attributes(params, place_id, review_id, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, report: report)
    else
      {:error, reason} when reason in [:polo_not_found, :review_not_found] ->
        render_error(conn, :not_found)

      {:error, :authentication_required} ->
        render_error(conn, :unauthorized)

      {:error, reason} when reason in [:idempotency_conflict, :review_already_reported] ->
        render_error(conn, :conflict)

      {:error, :request_in_progress} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> render_error(:conflict)

      {:error, reason}
      when reason in [:review_not_reportable, :review_report_not_allowed] ->
        render_error(conn, :unprocessable_entity)

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

  defp report_attributes(params, place_id, review_id, idempotency_key) do
    params
    |> Map.take(~w(reason_code details))
    |> Map.merge(%{
      "place_id" => place_id,
      "review_id" => review_id,
      "idempotency_key" => idempotency_key
    })
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
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
