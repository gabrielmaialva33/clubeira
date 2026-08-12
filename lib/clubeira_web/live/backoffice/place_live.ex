defmodule ClubeiraWeb.Backoffice.PlaceLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents
  alias ClubeiraWeb.Backoffice.PlaceProfileForm

  @lifecycle_command_fields ~w(
    action
    expected_polo_place_id
    expected_revision
    idempotency_key
    reason
  )
  @profile_form_fields ~w(
    public_email
    public_phone
    category_keys
    weekly_hours
    weekly_hours_sort
    weekly_hours_drop
    special_hours
    special_hours_sort
    special_hours_drop
  )

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Place details"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.backoffice_access.polos, params["polo"]) do
      {:ok, polo} -> load_place(socket, polo, params["polo_place_id"])
      {:invalid, fallback} -> redirect_invalid_polo(socket, fallback)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_navigate(socket, to: ~p"/admin/places?#{[polo: polo.slug]}")}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  def handle_event("transition_place", %{"lifecycle" => params}, socket)
      when is_map(params) do
    case refresh_account(socket) do
      {:ok, socket} ->
        process_transition_request(socket, params)

      :error ->
        redirect_expired_session(socket)
    end
  end

  def handle_event("transition_place", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The lifecycle request was invalid and was not processed.")
     )}
  end

  def handle_event(
        "validate_profile",
        %{"profile" => _params},
        %{assigns: %{profile_form_data: nil}} = socket
      ) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The public profile can no longer be edited in the current state.")
     )}
  end

  def handle_event("validate_profile", %{"profile" => params}, socket) when is_map(params) do
    {:noreply, assign_profile_form(socket, params, :validate)}
  end

  def handle_event("validate_profile", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The profile form was invalid and was not processed."))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) when is_map(params) do
    case refresh_account(socket) do
      {:ok, socket} -> process_profile_request(socket, params)
      :error -> redirect_expired_session(socket)
    end
  end

  def handle_event("save_profile", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The profile request was invalid and was not processed."))}
  end

  defp process_transition_request(%{assigns: %{lifecycle_form: nil}} = socket, _params) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("This lifecycle action is no longer available for the current state.")
     )}
  end

  defp process_transition_request(socket, params) do
    if retirement_confirmed?(params) do
      transition_place(socket, params)
    else
      {:noreply,
       socket
       |> assign(:lifecycle_form, form_from_params(params))
       |> put_flash(:error, gettext("Confirm the permanent retirement before continuing."))}
    end
  end

  defp load_place(socket, polo, polo_place_id) do
    if :manage_partners in polo.capabilities do
      scope = tenant_scope(socket.assigns.current_account_scope, polo)

      case load_place_data(scope, polo_place_id) do
        {:ok, place, categories} ->
          {:noreply,
           socket
           |> assign(:current_polo, polo)
           |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
           |> assign(:place_categories, categories)
           |> assign_place(place)}

        {:error, :place_not_found} ->
          redirect_missing(socket, polo)

        {:error, :partner_admin_required} ->
          redirect_unauthorized(socket, polo)

        {:error, reason} ->
          Logger.error("could not load backoffice place detail",
            polo_id: polo.id,
            polo_place_id: polo_place_id,
            reason: inspect(reason)
          )

          {:noreply,
           socket
           |> put_flash(:error, gettext("The place details are temporarily unavailable."))
           |> redirect(to: ~p"/admin/places?#{[polo: polo.slug]}")}
      end
    else
      redirect_unauthorized(socket, polo)
    end
  end

  defp select_polo(polos, nil), do: {:ok, List.first(polos)}

  defp select_polo(polos, slug) do
    case Enum.find(polos, &(&1.slug == slug)) do
      nil -> {:invalid, List.first(polos)}
      polo -> {:ok, polo}
    end
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp refresh_account(socket) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> {:ok, assign(socket, :current_account_scope, account_scope)}
      :error -> :error
    end
  end

  defp transition_place(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    place_id = socket.assigns.place.place.id

    attributes =
      params
      |> Map.take(@lifecycle_command_fields)
      |> Map.put("expected_polo_place_id", socket.assigns.place.id)
      |> Map.put("expected_revision", socket.assigns.place.revision)

    scope
    |> Directory.transition_place_participation(place_id, attributes)
    |> handle_transition_result(socket, params)
  end

  defp process_profile_request(%{assigns: %{profile_form: nil}} = socket, _params) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The public profile can no longer be edited in the current state.")
     )}
  end

  defp process_profile_request(socket, params) do
    changeset = profile_changeset(socket, params)

    case PlaceProfileForm.command(changeset) do
      {:ok, attributes} ->
        publish_profile(socket, attributes, changeset)

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:profile_form, to_form(changeset, as: :profile))
         |> put_flash(:error, gettext("Review the public profile before saving."))}
    end
  end

  defp publish_profile(socket, attributes, changeset) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    place_id = socket.assigns.place.place.id

    scope
    |> Directory.publish_place_profile(place_id, attributes)
    |> handle_profile_result(socket, changeset)
  end

  defp handle_profile_result({:ok, _result}, socket, _changeset) do
    refresh_after_profile(socket, gettext("The public profile was saved successfully."))
  end

  defp handle_profile_result({:error, :stale_place_profile}, socket, _changeset) do
    refresh_after_profile(
      socket,
      gettext("This profile changed in another session. Review the current version and retry."),
      :error
    )
  end

  defp handle_profile_result({:error, :idempotency_conflict}, socket, _changeset) do
    refresh_after_profile(
      socket,
      gettext("This profile request changed after it started. Review and submit it again."),
      :error
    )
  end

  defp handle_profile_result({:error, :request_in_progress}, socket, changeset) do
    {:noreply,
     socket
     |> assign(:profile_form, to_form(changeset, as: :profile))
     |> put_flash(:error, gettext("This profile request is still being processed."))}
  end

  defp handle_profile_result({:error, :invalid_categories}, socket, changeset) do
    changeset = Ecto.Changeset.add_error(changeset, :category_keys, "contains unavailable keys")

    {:noreply,
     socket
     |> assign(:profile_form, to_form(changeset, as: :profile))
     |> put_flash(:error, gettext("Select only currently available categories."))}
  end

  defp handle_profile_result({:error, %Ecto.Changeset{} = domain_changeset}, socket, changeset) do
    changeset = PlaceProfileForm.put_domain_errors(changeset, domain_changeset)

    {:noreply,
     socket
     |> assign(:profile_form, to_form(changeset, as: :profile))
     |> put_flash(:error, gettext("Review the public profile before saving."))}
  end

  defp handle_profile_result({:error, :place_not_found}, socket, _changeset) do
    redirect_missing(socket, socket.assigns.current_polo)
  end

  defp handle_profile_result({:error, :partner_admin_required}, socket, _changeset) do
    redirect_unauthorized(socket, socket.assigns.current_polo)
  end

  defp handle_profile_result({:error, reason}, socket, _changeset) do
    Logger.error("could not save backoffice place profile",
      polo_id: socket.assigns.current_polo.id,
      polo_place_id: socket.assigns.place.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The public profile could not be saved."))}
  end

  defp handle_transition_result({:ok, _result}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext("The participation lifecycle was updated successfully.")
    )
  end

  defp handle_transition_result({:error, :stale_place_participation}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext(
        "This participation changed in another session. Review the current state and retry."
      ),
      :error
    )
  end

  defp handle_transition_result({:error, reason}, socket, _params)
       when reason in [:invalid_place_participation_transition, :place_unavailable] do
    refresh_after_transition(
      socket,
      gettext("This lifecycle action is no longer available for the current state."),
      :error
    )
  end

  defp handle_transition_result({:error, :request_in_progress}, socket, params) do
    {:noreply,
     socket
     |> assign(:lifecycle_form, form_from_params(params))
     |> put_flash(
       :error,
       gettext("This request is still being processed. Retry with the same values.")
     )}
  end

  defp handle_transition_result({:error, :idempotency_conflict}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext(
        "This request changed after it started. Review the current state and submit again."
      ),
      :error
    )
  end

  defp handle_transition_result({:error, %Ecto.Changeset{} = changeset}, socket, _params) do
    {:noreply,
     socket
     |> assign(:lifecycle_form, to_form(changeset, as: :lifecycle))
     |> put_flash(:error, gettext("Review the lifecycle action before submitting."))}
  end

  defp handle_transition_result({:error, :place_not_found}, socket, _params) do
    redirect_missing(socket, socket.assigns.current_polo)
  end

  defp handle_transition_result({:error, :partner_admin_required}, socket, _params) do
    redirect_unauthorized(socket, socket.assigns.current_polo)
  end

  defp handle_transition_result({:error, reason}, socket, _params) do
    Logger.error("could not transition backoffice place participation",
      polo_id: socket.assigns.current_polo.id,
      place_id: socket.assigns.place.place.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The lifecycle action could not be completed."))}
  end

  defp refresh_after_transition(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    polo_place_id = socket.assigns.place.id

    case load_place_data(scope, polo_place_id) do
      {:ok, place, categories} ->
        {:noreply,
         socket
         |> assign(:place_categories, categories)
         |> assign_place(place)
         |> put_flash(flash_kind, message)}

      {:error, :place_not_found} ->
        redirect_missing(socket, socket.assigns.current_polo)

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload backoffice place after lifecycle transition",
          polo_id: socket.assigns.current_polo.id,
          polo_place_id: polo_place_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated participation could not be reloaded."))
         |> redirect(to: ~p"/admin/places?#{[polo: socket.assigns.current_polo.slug]}")}
    end
  end

  defp refresh_after_profile(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    polo_place_id = socket.assigns.place.id

    case load_place_data(scope, polo_place_id) do
      {:ok, place, categories} ->
        {:noreply,
         socket
         |> assign(:place_categories, categories)
         |> assign_place(place)
         |> put_flash(flash_kind, message)}

      {:error, :place_not_found} ->
        redirect_missing(socket, socket.assigns.current_polo)

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload backoffice place after profile update",
          polo_id: socket.assigns.current_polo.id,
          polo_place_id: polo_place_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated profile could not be reloaded."))
         |> redirect(to: ~p"/admin/places?#{[polo: socket.assigns.current_polo.slug]}")}
    end
  end

  defp load_place_data(scope, polo_place_id) do
    with {:ok, place} <- Directory.get_backoffice_place(scope, polo_place_id),
         {:ok, categories} <- Directory.list_backoffice_place_categories(scope) do
      {:ok, place, categories}
    end
  end

  defp assign_place(socket, place) do
    socket
    |> assign(:place, place)
    |> assign(:lifecycle_actions, lifecycle_actions(place.status))
    |> assign(:lifecycle_form, lifecycle_form(place))
    |> assign_profile_editor(place)
  end

  defp assign_profile_editor(socket, %{status: "active"} = place) do
    profile_form_data = PlaceProfileForm.from_place(place, profile_idempotency_key())

    socket
    |> assign(:profile_form_data, profile_form_data)
    |> assign(:profile_form, to_form(PlaceProfileForm.change(profile_form_data), as: :profile))
    |> assign(
      :profile_category_options,
      profile_category_options(place, socket.assigns.place_categories)
    )
  end

  defp assign_profile_editor(socket, _place) do
    socket
    |> assign(:profile_form_data, nil)
    |> assign(:profile_form, nil)
    |> assign(:profile_category_options, [])
  end

  defp assign_profile_form(socket, params, action) do
    changeset = profile_changeset(socket, params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :profile_form, to_form(changeset, as: :profile))
  end

  defp profile_changeset(socket, params) do
    params =
      params
      |> Map.take(@profile_form_fields)
      |> Map.put("expected_polo_place_id", socket.assigns.place.id)
      |> Map.put("expected_revision", profile_revision(socket.assigns.place.profile))
      |> Map.put("idempotency_key", socket.assigns.profile_form_data.idempotency_key)

    PlaceProfileForm.change(socket.assigns.profile_form_data, params)
  end

  defp profile_category_options(place, categories) do
    active_options = Enum.map(categories, &{&1.name, &1.key})

    retired_options =
      case place.profile do
        nil ->
          []

        profile ->
          profile.categories
          |> Enum.reject(&(&1.status == "active"))
          |> Enum.map(&{"#{&1.name} (#{gettext("retired")})", &1.key})
      end

    (active_options ++ retired_options)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(fn {label, _key} -> label end)
  end

  defp profile_revision(nil), do: 0
  defp profile_revision(profile), do: profile.revision

  defp lifecycle_form(%{status: status}) when status in ["invited", "retired"], do: nil

  defp lifecycle_form(place) do
    [{_label, default_action} | _remaining] = lifecycle_actions(place.status)

    to_form(
      Directory.change_place_participation_lifecycle(%{
        action: default_action,
        reason: "",
        expected_polo_place_id: place.id,
        expected_revision: place.revision,
        idempotency_key: lifecycle_idempotency_key(),
        confirm_retire: false
      }),
      as: :lifecycle
    )
  end

  defp form_from_params(params) do
    params
    |> Directory.change_place_participation_lifecycle()
    |> to_form(as: :lifecycle)
  end

  defp lifecycle_actions("active"),
    do: [{gettext("Suspend"), "suspend"}, {gettext("Retire permanently"), "retire"}]

  defp lifecycle_actions("suspended"),
    do: [{gettext("Reactivate"), "reactivate"}, {gettext("Retire permanently"), "retire"}]

  defp lifecycle_actions(_status), do: []

  defp lifecycle_idempotency_key do
    "place-lifecycle-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp profile_idempotency_key do
    "place-profile-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp retirement_confirmed?(params) do
    case params |> Map.get("action") |> normalize_action() do
      "retire" -> Map.get(params, "confirm_retire") in ["true", "on"]
      _other_action -> true
    end
  end

  defp normalize_action(action) when is_binary(action),
    do: action |> String.trim() |> String.downcase()

  defp normalize_action(action), do: action

  defp redirect_invalid_polo(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: ~p"/admin/places?#{[polo: polo.slug]}")}
  end

  defp redirect_missing(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The place was not found in this polo."))
     |> redirect(to: ~p"/admin/places?#{[polo: polo.slug]}")}
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage places."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp profile_label(nil), do: gettext("Missing profile")
  defp profile_label(_profile), do: gettext("Published profile")

  defp weekday_options do
    [
      {gettext("Monday"), 1},
      {gettext("Tuesday"), 2},
      {gettext("Wednesday"), 3},
      {gettext("Thursday"), 4},
      {gettext("Friday"), 5},
      {gettext("Saturday"), 6},
      {gettext("Sunday"), 7}
    ]
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("invited"), do: gettext("Invited")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("retired"), do: gettext("Retired")
end
