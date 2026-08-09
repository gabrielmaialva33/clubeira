defmodule ClubeiraWeb.PartnerReviewResponseController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def update(conn, %{"polo_slug" => polo_slug, "review_id" => review_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, response} <-
           Reviews.put_partner_response(
             scope(conn, route.polo_id),
             review_id,
             %{
               "body" => Map.get(params, "body"),
               "idempotency_key" => idempotency_key
             }
           ) do
      render(conn, :show, response: response)
    else
      {:error, reason} when reason in [:polo_not_found, :review_not_found, :place_not_found] ->
        render_error(conn, :not_found)

      {:error, :partner_access_required} ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_idempotency_conflict(conn, reason)

      {:error, reason}
      when reason in [:review_not_responseable, :invalid_review_response_transition] ->
        render_error(conn, :conflict, Atom.to_string(reason))

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
