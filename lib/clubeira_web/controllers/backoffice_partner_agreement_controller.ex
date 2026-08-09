defmodule ClubeiraWeb.BackofficePartnerAgreementController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Partnerships
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @publish_fields ~w(
    agreement_number name valid_from valid_until signed_at settlement_model
    redemption_sla_seconds organization_ids brand_ids polo_place_ids edition_ids
    benefit_offer_version_ids
  )
  @query_fields ~w(after limit status)

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Partnerships.publish_agreement(
             scope(conn, route.polo_id),
             params |> Map.take(@publish_fields) |> Map.put("idempotency_key", key)
           ) do
      conn
      |> put_status(if(result.replayed?, do: :ok, else: :created))
      |> render(:show, agreement: result.agreement)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :agreement_number_taken} ->
        render_error(conn, :conflict, "agreement_number_taken")

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")

      {:error, :invalid_signed_at} ->
        render_error(conn, :unprocessable_entity, "invalid_signed_at")

      {:error, reason}
      when reason in [
             :organization_not_found,
             :brand_not_authorized,
             :polo_place_not_authorized,
             :edition_not_found,
             :benefit_offer_version_not_found
           ] ->
        render_error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, {:tenant_scope_mismatch, _setting}} ->
        render_error(conn, :conflict, "tenant_scope_mismatch")

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not publish partner agreement: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Partnerships.list_agreements(
             scope(conn, route.polo_id),
             Map.take(params, @query_fields)
           ) do
      render(conn, :index, agreements: result.agreements, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, :invalid_partner_agreement_status} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list partner agreements: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  def show(conn, %{"polo_slug" => polo_slug, "agreement_id" => agreement_id}) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, agreement} <-
           Partnerships.get_agreement(scope(conn, route.polo_id), agreement_id) do
      render(conn, :show, agreement: agreement)
    else
      {:error, reason} when reason in [:polo_not_found, :partner_agreement_not_found] ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason} ->
        Logger.error("could not get partner agreement: #{inspect(reason)}")
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
      [key] -> {:ok, key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp render_conflict(conn, :request_in_progress) do
    conn
    |> put_resp_header("retry-after", "1")
    |> render_error(:conflict, "request_in_progress")
  end

  defp render_conflict(conn, :idempotency_conflict),
    do: render_error(conn, :conflict, "idempotency_conflict")

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
