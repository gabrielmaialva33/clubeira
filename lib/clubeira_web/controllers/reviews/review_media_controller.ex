defmodule ClubeiraWeb.Reviews.ReviewMediaController do
  use ClubeiraWeb, :controller

  alias Clubeira.Polos
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def create(
        conn,
        %{
          "polo_slug" => polo_slug,
          "place_id" => place_id,
          "review_id" => review_id
        } = params
      ) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Reviews.register_media(
             authenticated_scope(conn, route.polo_id),
             place_id,
             review_id,
             params
             |> Map.take(~w(storage_key position))
             |> Map.put("idempotency_key", idempotency_key)
           ) do
      conn
      |> put_status(if(result.created?, do: :created, else: :ok))
      |> render(:show, media: result.media)
    else
      {:error, reason} when reason in [:polo_not_found, :place_not_found, :review_not_found] ->
        render_error(conn, :not_found)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_idempotency_conflict(conn, reason)

      {:error, :review_media_conflict} ->
        render_error(conn, :conflict, "review_media_conflict")

      {:error, reason}
      when reason in [
             :media_not_verified,
             :invalid_media_descriptor,
             :media_storage_unavailable
           ] ->
        render_error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  def show(conn, %{"polo_slug" => polo_slug, "media_id" => media_id}) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, url} <-
           Reviews.public_media_url(
             Scope.new!(route.polo_id, request_id: conn.assigns.request_id),
             media_id
           ) do
      redirect(conn, external: url)
    else
      {:error, reason} when reason in [:polo_not_found, :review_media_not_found] ->
        render_error(conn, :not_found)

      {:error, _storage_error} ->
        render_error(conn, :service_unavailable, "media_delivery_unavailable")
    end
  end

  defp authenticated_scope(conn, polo_id) do
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
