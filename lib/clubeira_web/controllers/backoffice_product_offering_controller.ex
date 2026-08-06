defmodule ClubeiraWeb.BackofficeProductOfferingController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @offering_fields ~w(code name description)
  @cycle_fields ~w(policy interval_unit interval_count)
  @effective_fields ~w(starts_at ends_at)
  @price_fields ~w(currency amount)
  @benefit_fields ~w(benefit_offer_version_id allowance_per_cycle consumption_unit)
  @query_fields ~w(after code limit status)

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Subscriptions.list_product_offerings(
             scope(conn, route.polo_id),
             Map.take(params, @query_fields)
           ) do
      render(conn, :index,
        product_offerings: result.product_offerings,
        page: result.page
      )
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason}
      when reason in [:invalid_product_offering_code, :invalid_product_offering_status] ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list product offerings: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Subscriptions.publish_product_offering(
             scope(conn, route.polo_id),
             publishing_attributes(params, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, result: result)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :partner_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :benefit_offer_version_not_found} ->
        render_error(conn, :not_found, "benefit_offer_version_not_found")

      {:error, :benefit_configuration_unavailable} ->
        render_error(conn, :conflict, "benefit_configuration_unavailable")

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :product_offering_code_taken} ->
        render_error(conn, :conflict, "product_offering_code_conflict")

      {:error, {:tenant_scope_mismatch, _setting}} ->
        render_error(conn, :conflict, "tenant_scope_mismatch")

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

  defp publishing_attributes(params, idempotency_key) do
    offering = map_param(params, "offering")
    cycle = map_param(offering, "cycle")
    effective_during = map_param(offering, "effective_during")

    %{
      "offering" =>
        offering
        |> Map.take(@offering_fields)
        |> Map.put("cycle", Map.take(cycle, @cycle_fields))
        |> Map.put("effective_during", Map.take(effective_during, @effective_fields)),
      "price" => params |> map_param("price") |> Map.take(@price_fields),
      "benefits" => benefit_params(params),
      "idempotency_key" => idempotency_key
    }
  end

  defp benefit_params(params) do
    case Map.get(params, "benefits") do
      benefits when is_list(benefits) ->
        Enum.map(benefits, fn
          benefit when is_map(benefit) -> Map.take(benefit, @benefit_fields)
          _invalid -> %{}
        end)

      _invalid ->
        []
    end
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
