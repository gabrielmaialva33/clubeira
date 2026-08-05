defmodule ClubeiraWeb.BackofficePartnerController do
  use ClubeiraWeb, :controller

  alias Clubeira.Directory
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @organization_fields ~w(legal_name trade_name cnpj)
  @place_fields ~w(name slug)
  @address_fields ~w(postal_code street number complement district)

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Directory.onboard_partner(
             scope(conn, route.polo_id),
             onboarding_attributes(params, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, result: result)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason}
      when reason in [
             :cnpj_already_registered,
             :place_slug_taken,
             :idempotency_conflict,
             :request_in_progress
           ] ->
        render_conflict(conn, reason)

      {:error, :invalid_idempotency_key} ->
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

  defp onboarding_attributes(params, idempotency_key) do
    place = map_param(params, "place")
    address = map_param(place, "address")

    %{
      "organization" => params |> map_param("organization") |> Map.take(@organization_fields),
      "place" =>
        place
        |> Map.take(@place_fields)
        |> Map.put("address", Map.take(address, @address_fields)),
      "idempotency_key" => idempotency_key
    }
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

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end

  defp render_conflict(conn, :request_in_progress) do
    conn
    |> put_resp_header("retry-after", "1")
    |> render_error(:conflict, "request_in_progress")
  end

  defp render_conflict(conn, :idempotency_conflict) do
    render_error(conn, :conflict, "idempotency_conflict")
  end

  defp render_conflict(conn, reason)
       when reason in [:cnpj_already_registered, :place_slug_taken] do
    render_error(conn, :conflict, "partner_conflict")
  end

  defp render_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{code: code}))
  end
end
