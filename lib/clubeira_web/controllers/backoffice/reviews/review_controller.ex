defmodule ClubeiraWeb.Backoffice.ReviewController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @moderation_fields ~w(action reason)

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, page} <- Reviews.list_for_moderation(scope(conn, route.polo_id), params) do
      render(conn, :index, reviews: page.reviews, page: page.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :moderator_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, :invalid_review_status} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  def create_action(
        conn,
        %{"polo_slug" => polo_slug, "review_id" => review_id} = params
      ) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Reviews.moderate(
             scope(conn, route.polo_id),
             moderation_attributes(params, review_id, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create_action, review: result.review, action: result.action)
    else
      {:error, reason} when reason in [:polo_not_found, :review_not_found] ->
        render_error(conn, :not_found)

      {:error, :moderator_required} ->
        render_error(conn, :forbidden)

      {:error, reason}
      when reason in [:idempotency_conflict, :request_in_progress, :invalid_review_transition] ->
        render_error(conn, :conflict)

      {:error, reason} when reason in [:invalid_idempotency_key] ->
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

  defp moderation_attributes(params, review_id, idempotency_key) do
    params
    |> Map.take(@moderation_fields)
    |> Map.put("review_id", review_id)
    |> Map.put("idempotency_key", idempotency_key)
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
end
