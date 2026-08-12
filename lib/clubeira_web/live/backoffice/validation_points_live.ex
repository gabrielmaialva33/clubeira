defmodule ClubeiraWeb.Backoffice.ValidationPointsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Redemptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit place_id status)
  @provision_fields ~w(name expires_at idempotency_key)
  @lifecycle_fields ~w(action reason idempotency_key)
  @rotation_fields ~w(expires_at idempotency_key)
  @revocation_fields ~w(idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:validation_points, dom_id: &"validation-point-#{&1.id}")
     |> assign(:revealed_secret, nil)
     |> assign(:page_title, gettext("Validation points")),
     temporary_assigns: [revealed_secret: nil]}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_partners in polo.capabilities do
      load_workspace(socket, polo, params)
    else
      redirect_unauthorized(socket, polo)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: validation_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:place_id, filters["place_id"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/validation-points?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The validation-point filters were invalid."))}
  end

  def handle_event("select_validation_place", %{"place" => %{"id" => place_id}}, socket)
      when is_binary(place_id) do
    case Enum.find(socket.assigns.available_places, &(&1.place.id == place_id)) do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The selected place is not available for provisioning.")
         )}

      place ->
        {:noreply, assign_selected_place(socket, place)}
    end
  end

  def handle_event("select_validation_place", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The selected place is not available for provisioning."))}
  end

  def handle_event("provision_validation_point", %{"validation_point" => params}, socket)
      when is_map(params) do
    with_refreshed_session(socket, &provision_point(&1, params))
  end

  def handle_event("provision_validation_point", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The provisioning request was invalid."))}
  end

  def handle_event(
        "transition_validation_point",
        %{"point_id" => point_id, "lifecycle" => params},
        socket
      )
      when is_binary(point_id) and is_map(params) do
    if Map.has_key?(socket.assigns.lifecycle_forms, point_id) do
      with_refreshed_session(socket, &transition_point(&1, point_id, params))
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("The validation point is not available for this action.")
       )}
    end
  end

  def handle_event("transition_validation_point", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The lifecycle request was invalid."))}
  end

  def handle_event(
        "rotate_validation_credential",
        %{"credential_id" => credential_id, "rotation" => params},
        socket
      )
      when is_binary(credential_id) and is_map(params) do
    if Map.has_key?(socket.assigns.rotation_forms, credential_id) do
      with_refreshed_session(socket, &rotate_credential(&1, credential_id, params))
    else
      {:noreply,
       put_flash(socket, :error, gettext("The credential is not available for rotation."))}
    end
  end

  def handle_event("rotate_validation_credential", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The credential rotation request was invalid."))}
  end

  def handle_event(
        "revoke_validation_credential",
        %{"credential_id" => credential_id, "revocation" => params},
        socket
      )
      when is_binary(credential_id) and is_map(params) do
    if Map.has_key?(socket.assigns.revocation_forms, credential_id) do
      with_refreshed_session(socket, &revoke_credential(&1, credential_id, params))
    else
      {:noreply,
       put_flash(socket, :error, gettext("The credential is not available for revocation."))}
    end
  end

  def handle_event("revoke_validation_credential", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The credential revocation request was invalid."))}
  end

  defp load_workspace(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)
    query_params = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Redemptions.list_validation_points(scope, query_params),
         {:ok, %{places: places}} <-
           Directory.list_backoffice_places(scope, %{"status" => "active", "limit" => "100"}) do
      selected_place = select_place(places, params["place_id"])

      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(
         :filter_form,
         to_form(
           %{
             "status" => Map.get(params, "status", ""),
             "place_id" => Map.get(params, "place_id", "")
           },
           as: :filters
         )
       )
       |> assign(:available_places, places)
       |> assign_selected_place(selected_place)
       |> assign(:provision_form, provision_form())
       |> assign_result(polo, query_params, params, result)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason}
      when reason in [:invalid_pagination, :invalid_place_id, :invalid_validation_point_status] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The validation-point filters were invalid and have been cleared.")
         )
         |> redirect(to: validation_path(polo.slug))}

      {:error, reason} ->
        Logger.error("could not load validation-point workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The validation workspace is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp provision_point(%{assigns: %{selected_place: nil}} = socket, _params) do
    {:noreply, put_flash(socket, :error, gettext("Select an active place before provisioning."))}
  end

  defp provision_point(socket, params) do
    {secret, digest} = generate_credential()
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    attributes =
      params
      |> Map.take(@provision_fields)
      |> Map.put("secret_sha256", digest)

    case Redemptions.provision_validation_point(
           scope,
           socket.assigns.selected_place.place.id,
           attributes
         ) do
      {:ok, result} ->
        refresh_inventory(
          socket,
          gettext("The validation point was provisioned. Copy the credential now."),
          :info,
          %{secret: secret, point_name: result["name"], action: :provisioned}
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:provision_form, to_form(changeset, as: :validation_point))
         |> put_flash(:error, gettext("Review the validation-point data before provisioning."))}

      {:error, reason}
      when reason in [
             :credential_already_registered,
             :idempotency_conflict,
             :invalid_expiration,
             :place_not_found,
             :request_in_progress
           ] ->
        refresh_inventory(
          socket,
          gettext("The validation-point state changed. Review the inventory and retry."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        command_failure(socket, "provision validation point", reason)
    end
  end

  defp transition_point(socket, point_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Redemptions.transition_validation_point(
           scope,
           point_id,
           Map.take(params, @lifecycle_fields)
         ) do
      {:ok, _result} ->
        refresh_inventory(socket, gettext("The validation-point lifecycle was updated."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :lifecycle_forms,
           Map.put(
             socket.assigns.lifecycle_forms,
             point_id,
             to_form(changeset, as: :lifecycle)
           )
         )
         |> put_flash(:error, gettext("Review the lifecycle decision before submitting."))}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :invalid_validation_point_transition,
             :request_in_progress,
             :validation_credential_revoked,
             :validation_point_not_found,
             :validation_point_unavailable
           ] ->
        refresh_inventory(
          socket,
          gettext("The validation point changed before this action completed."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        command_failure(socket, "transition validation point", reason)
    end
  end

  defp rotate_credential(socket, credential_id, params) do
    {secret, digest} = generate_credential()
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    attributes =
      params
      |> Map.take(@rotation_fields)
      |> Map.put("secret_sha256", digest)

    case Redemptions.rotate_validation_credential(scope, credential_id, attributes) do
      {:ok, result} ->
        refresh_inventory(
          socket,
          gettext("The credential was rotated. Copy the replacement now."),
          :info,
          %{secret: secret, point_name: result["validation_point_name"], action: :rotated}
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :rotation_forms,
           Map.put(
             socket.assigns.rotation_forms,
             credential_id,
             to_form(changeset, as: :rotation)
           )
         )
         |> put_flash(:error, gettext("Review the credential expiration before rotating."))}

      {:error, reason}
      when reason in [
             :credential_already_registered,
             :idempotency_conflict,
             :invalid_expiration,
             :request_in_progress,
             :validation_credential_not_found,
             :validation_credential_revoked,
             :validation_credential_stale,
             :validation_credential_unavailable,
             :validation_point_not_found
           ] ->
        refresh_inventory(
          socket,
          gettext("The credential changed before rotation completed. Review the inventory."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        command_failure(socket, "rotate validation credential", reason)
    end
  end

  defp revoke_credential(socket, credential_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Redemptions.revoke_validation_credential(
           scope,
           credential_id,
           Map.take(params, @revocation_fields)
         ) do
      {:ok, _result} ->
        refresh_inventory(socket, gettext("The validation credential was revoked."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :revocation_forms,
           Map.put(
             socket.assigns.revocation_forms,
             credential_id,
             to_form(changeset, as: :revocation)
           )
         )
         |> put_flash(:error, gettext("The credential revocation request was invalid."))}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :request_in_progress,
             :validation_credential_not_found,
             :validation_credential_revoked,
             :validation_credential_stale,
             :validation_credential_unavailable,
             :validation_point_not_found
           ] ->
        refresh_inventory(
          socket,
          gettext("The credential changed before revocation completed."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        command_failure(socket, "revoke validation credential", reason)
    end
  end

  defp refresh_inventory(socket, message, flash_kind \\ :info, revealed_secret \\ nil) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Redemptions.list_validation_points(scope, socket.assigns.query_params) do
      {:ok, result} ->
        params = socket.assigns.query_params

        {:noreply,
         socket
         |> assign(:provision_form, provision_form())
         |> assign(:revealed_secret, revealed_secret)
         |> assign_result(socket.assigns.current_polo, params, params, result)
         |> put_flash(flash_kind, message)}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload validation-point inventory",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated validation inventory could not be reloaded."))
         |> redirect(to: validation_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_result(socket, polo, query_params, path_params, result) do
    mutable = Enum.reject(result.validation_points, &(&1.status == "retired"))

    credential_points =
      Enum.filter(mutable, fn point ->
        match?(%{status: "active"}, point.credential)
      end)

    socket
    |> assign(:query_params, query_params)
    |> assign(:limit_param, Map.get(path_params, "limit"))
    |> assign(:next_page_path, next_page_path(polo, path_params, result.page))
    |> assign(:lifecycle_forms, Map.new(mutable, &{&1.id, lifecycle_form()}))
    |> assign(
      :rotation_forms,
      Map.new(credential_points, &{&1.credential.id, rotation_form()})
    )
    |> assign(
      :revocation_forms,
      Map.new(credential_points, &{&1.credential.id, revocation_form()})
    )
    |> assign(:page, result.page)
    |> stream(:validation_points, result.validation_points, reset: true)
  end

  defp provision_form do
    %{
      "expires_at" => DateTime.add(DateTime.utc_now(), 30, :day),
      "idempotency_key" => "validation-point-provision-#{uuid7()}"
    }
    |> Redemptions.change_validation_point_provision_request()
    |> to_form(as: :validation_point)
  end

  defp lifecycle_form do
    %{"action" => "", "reason" => "", "idempotency_key" => "validation-lifecycle-#{uuid7()}"}
    |> Redemptions.change_validation_point_lifecycle_request()
    |> to_form(as: :lifecycle)
  end

  defp rotation_form do
    %{
      "expires_at" => DateTime.add(DateTime.utc_now(), 30, :day),
      "idempotency_key" => "validation-rotation-#{uuid7()}"
    }
    |> Redemptions.change_validation_credential_rotation_request()
    |> to_form(as: :rotation)
  end

  defp revocation_form do
    %{"idempotency_key" => "validation-revocation-#{uuid7()}"}
    |> Redemptions.change_validation_credential_revocation_request()
    |> to_form(as: :revocation)
  end

  defp generate_credential do
    bytes = :crypto.strong_rand_bytes(32)

    {
      Base.url_encode64(bytes, padding: false),
      :sha256 |> :crypto.hash(bytes) |> Base.url_encode64(padding: false)
    }
  end

  defp assign_selected_place(socket, nil) do
    socket
    |> assign(:selected_place, nil)
    |> assign(:place_form, to_form(%{"id" => ""}, as: :place))
  end

  defp assign_selected_place(socket, place) do
    socket
    |> assign(:selected_place, place)
    |> assign(:place_form, to_form(%{"id" => place.place.id}, as: :place))
  end

  defp select_place([], _place_id), do: nil

  defp select_place(places, place_id) do
    Enum.find(places, &(&1.place.id == place_id)) || List.first(places)
  end

  defp with_refreshed_session(socket, callback) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> callback.(assign(socket, :current_account_scope, account_scope))
      :error -> redirect_expired_session(socket)
    end
  end

  defp command_failure(socket, operation, reason) do
    Logger.error("could not #{operation} from backoffice",
      polo_id: socket.assigns.current_polo.id,
      reason: inspect(reason)
    )

    {:noreply,
     put_flash(socket, :error, gettext("The validation action could not be completed."))}
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp maybe_put_filter(query, _key, value) when value in [nil, ""], do: query
  defp maybe_put_filter(query, key, value), do: query ++ [{key, value}]

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query =
      [polo: polo.slug]
      |> maybe_put_filter(:status, params["status"])
      |> maybe_put_filter(:place_id, params["place_id"])
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/validation-points?#{query}"
  end

  defp validation_path(polo_slug), do: ~p"/admin/validation-points?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage validation points."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp status_label("active"), do: gettext("Active")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("retired"), do: gettext("Retired")

  defp lifecycle_options("active"),
    do: [{gettext("Suspend"), "suspend"}, {gettext("Retire"), "retire"}]

  defp lifecycle_options("suspended"),
    do: [{gettext("Reactivate"), "reactivate"}, {gettext("Retire"), "retire"}]

  defp lifecycle_options(_status), do: []
end
