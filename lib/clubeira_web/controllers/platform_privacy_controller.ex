defmodule ClubeiraWeb.PlatformPrivacyController do
  use ClubeiraWeb, :controller

  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @purpose_fields ~w(name legal_basis legal_document_version_id status)
  @transition_fields ~w(action expected_status rejection_reason)

  def index_processing_purposes(conn, _params) do
    case Privacy.list_processing_purposes(actor_scope(conn)) do
      {:ok, purposes} -> render(conn, :processing_purposes, purposes: purposes)
      {:error, reason} -> render_domain_error(conn, reason)
    end
  end

  def put_processing_purpose(conn, %{"purpose_code" => purpose_code} = params) do
    case Privacy.put_processing_purpose(
           actor_scope(conn),
           purpose_code,
           Map.take(params, @purpose_fields)
         ) do
      {:ok, purpose} -> render(conn, :processing_purpose, purpose: purpose)
      {:error, reason} -> render_domain_error(conn, reason)
    end
  end

  def index_requests(conn, params) do
    case Privacy.list_platform_requests(
           actor_scope(conn),
           Map.take(params, ~w(status limit after))
         ) do
      {:ok, result} ->
        render(conn, :requests, requests: result.requests, page: result.page)

      {:error, reason} ->
        render_domain_error(conn, reason)
    end
  end

  def transition_request(conn, %{"request_id" => request_id} = params) do
    case Privacy.transition_request(
           actor_scope(conn),
           request_id,
           Map.take(params, @transition_fields)
         ) do
      {:ok, %{request: request}} -> render(conn, :request, request: request)
      {:error, reason} -> render_domain_error(conn, reason)
    end
  end

  defp actor_scope(conn) do
    account_scope = conn.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp render_domain_error(conn, %Ecto.Changeset{}),
    do: render_error(conn, :unprocessable_entity)

  defp render_domain_error(conn, :platform_privacy_officer_required),
    do: render_error(conn, :forbidden, "platform_privacy_officer_required")

  defp render_domain_error(conn, :privacy_request_not_found),
    do: render_error(conn, :not_found)

  defp render_domain_error(conn, reason)
       when reason in [
              :invalid_processing_purpose,
              :invalid_pagination,
              :invalid_privacy_request_status
            ],
       do: render_error(conn, :unprocessable_entity)

  defp render_domain_error(conn, reason)
       when reason in [
              :consent_notice_unavailable,
              :legal_document_unavailable,
              :stale_privacy_request,
              :invalid_privacy_request_transition
            ],
       do: render_error(conn, :conflict, Atom.to_string(reason))

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
