defmodule ClubeiraWeb.Reviews.ReviewController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @review_fields ~w(rating title body source_redemption_id)
  @unprocessable_review_errors ~w(
    actor_required
    actor_unavailable
    polo_unavailable
    review_already_exists
    review_policy_unavailable
    reviews_disabled
    source_redemption_unavailable
  )a

  def index(conn, %{"polo_slug" => polo_slug, "place_id" => place_id} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, page} <-
           Reviews.list_public(
             Scope.new!(route.polo_id, request_id: conn.assigns.request_id),
             place_id,
             params
           ) do
      render(conn, :index, reviews: page.reviews, page: page.page, polo_slug: polo_slug)
    else
      {:error, reason} when reason in [:polo_not_found, :place_not_found] ->
        render_error(conn, :not_found)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)
    end
  end

  def create(conn, %{"polo_slug" => polo_slug, "place_id" => place_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Reviews.submit_verified(
             review_scope(conn, route.polo_id),
             review_attributes(params, place_id, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, review: result.review, revision: result.revision)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_error(conn, :conflict)

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :unprocessable_entity)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} when reason in @unprocessable_review_errors ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp review_scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp review_attributes(params, place_id, idempotency_key) do
    params
    |> Map.take(@review_fields)
    |> Map.put("place_id", place_id)
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
