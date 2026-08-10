defmodule ClubeiraWeb.Member.PrivacyController do
  use ClubeiraWeb, :controller

  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def index_consents(conn, _params) do
    case Privacy.list_consents(actor_scope(conn)) do
      {:ok, consents} -> render(conn, :consents, consents: consents)
      {:error, :profile_required} -> render_error(conn, :conflict, "profile_required")
    end
  end

  def update_consent(conn, %{"purpose_code" => purpose_code} = params) do
    attributes = Map.take(params, ~w(state legal_document_version_id))

    case Privacy.put_consent(actor_scope(conn), purpose_code, attributes) do
      {:ok, consent} -> render(conn, :consent, consent: consent)
      {:error, %Ecto.Changeset{}} -> render_error(conn, :unprocessable_entity)
      {:error, :profile_required} -> render_error(conn, :conflict, "profile_required")
      {:error, :consent_unavailable} -> render_error(conn, :conflict, "consent_unavailable")
    end
  end

  def index_requests(conn, _params) do
    case Privacy.list_requests(actor_scope(conn)) do
      {:ok, requests} -> render(conn, :requests, requests: requests)
      {:error, :profile_required} -> render_error(conn, :conflict, "profile_required")
    end
  end

  def create_request(conn, params) do
    attributes = Map.take(params, ~w(client_request_id request_type))

    case Privacy.submit_request(actor_scope(conn), attributes) do
      {:ok, %{request: request, replayed?: replayed?}} ->
        conn
        |> put_status(if(replayed?, do: :ok, else: :created))
        |> render(:request, request: request)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, :profile_required} ->
        render_error(conn, :conflict, "profile_required")

      {:error, :idempotency_conflict} ->
        render_error(conn, :conflict, "idempotency_conflict")
    end
  end

  defp actor_scope(conn) do
    account_scope = conn.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
