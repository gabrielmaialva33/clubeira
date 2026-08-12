defmodule ClubeiraWeb.Backoffice.PlaceProfileController do
  use ClubeiraWeb, :controller

  alias Clubeira.Directory
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @profile_fields ~w(
    contact
    category_keys
    weekly_hours
    special_hours
    expected_polo_place_id
    expected_revision
  )
  @contact_fields ~w(email phone)
  @weekly_hour_fields ~w(weekday opens_at closes_at)
  @special_hour_fields ~w(date kind windows)
  @special_window_fields ~w(opens_at closes_at)

  def update(conn, %{"polo_slug" => polo_slug, "place_id" => place_id} = params) do
    with :ok <- validate_profile_body(conn.body_params),
         {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Directory.publish_place_profile(
             scope(conn, route.polo_id),
             place_id,
             profile_attributes(params, idempotency_key)
           ) do
      render(conn, :update, result: result)
    else
      {:error, reason} when reason in [:polo_not_found, :place_not_found] ->
        render_error(conn, :not_found)

      {:error, reason} when reason in [:partner_admin_required, :partner_access_required] ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in [:idempotency_conflict, :request_in_progress] ->
        render_conflict(conn, reason)

      {:error, :stale_place_profile} ->
        render_conflict(conn, :stale_place_profile)

      {:error, :invalid_categories} ->
        render_error(conn, :unprocessable_entity, "invalid_categories")

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :unprocessable_entity)

      {:error, :invalid_profile_payload} ->
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

  defp profile_attributes(params, idempotency_key) do
    params
    |> Map.take(@profile_fields)
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp validate_profile_body(body_params)
       when is_map(body_params) and not is_struct(body_params) do
    with :ok <- validate_object_keys(body_params, @profile_fields),
         :ok <- validate_object_keys(Map.get(body_params, "contact"), @contact_fields),
         :ok <- validate_list_keys(Map.get(body_params, "weekly_hours"), @weekly_hour_fields),
         :ok <- validate_special_hours(Map.get(body_params, "special_hours")) do
      :ok
    end
  end

  defp validate_profile_body(_body_params), do: {:error, :invalid_profile_payload}

  defp validate_object_keys(value, allowed_fields)
       when is_map(value) and not is_struct(value) do
    if Map.keys(value) -- allowed_fields == [],
      do: :ok,
      else: {:error, :invalid_profile_payload}
  end

  defp validate_object_keys(_value, _allowed_fields), do: :ok

  defp validate_list_keys(values, allowed_fields) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_object_keys(value, allowed_fields) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_list_keys(_values, _allowed_fields), do: :ok

  defp validate_special_hours(hours) when is_list(hours) do
    Enum.reduce_while(hours, :ok, fn hour, :ok ->
      with :ok <- validate_object_keys(hour, @special_hour_fields),
           windows when is_list(windows) <- map_value(hour, "windows", []),
           :ok <- validate_list_keys(windows, @special_window_fields) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
        windows when not is_list(windows) -> {:cont, :ok}
      end
    end)
  end

  defp validate_special_hours(_hours), do: :ok

  defp map_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_value(_map, _key, default), do: default

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

  defp render_conflict(conn, :stale_place_profile) do
    render_error(conn, :conflict, "stale_place_profile")
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
