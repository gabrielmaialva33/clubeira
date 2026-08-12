defmodule ClubeiraWeb.Partner.PlaceLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.Backoffice.PlaceProfileForm
  alias ClubeiraWeb.PartnerAuth
  alias ClubeiraWeb.PartnerComponents

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
    {:ok, assign(socket, :page_title, gettext("Place profile"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.partner_access.polos, params["polo_slug"]) do
      {:ok, polo} -> load_place(socket, polo, params["polo_place_id"])
      :error -> redirect_invalid_polo(socket)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.partner_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_navigate(socket, to: places_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  def handle_event("validate_profile", %{"profile" => params}, socket) when is_map(params) do
    {:noreply, assign_profile_form(socket, params, :validate)}
  end

  def handle_event("validate_profile", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The profile form was invalid and was not processed."))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) when is_map(params) do
    case refresh_partner(socket) do
      {:ok, socket} -> process_profile_request(socket, params)
      :error -> redirect_unauthorized(socket)
    end
  end

  def handle_event("save_profile", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The profile request was invalid and was not processed."))}
  end

  defp load_place(socket, polo, polo_place_id) do
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

      {:error, :partner_access_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not load partner place detail",
          polo_id: polo.id,
          polo_place_id: polo_place_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The place profile is temporarily unavailable."))
         |> redirect(to: places_path(polo.slug))}
    end
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
    changeset =
      changeset
      |> Ecto.Changeset.add_error(:category_keys, "contains unavailable keys")
      |> Map.put(:action, :publish_place_profile)

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

  defp handle_profile_result({:error, reason}, socket, _changeset)
       when reason in [:partner_access_required, :partner_admin_required] do
    redirect_unauthorized(socket)
  end

  defp handle_profile_result({:error, reason}, socket, _changeset) do
    Logger.error("could not save partner place profile",
      polo_id: socket.assigns.current_polo.id,
      polo_place_id: socket.assigns.place.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The public profile could not be saved."))}
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

      {:error, :partner_access_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not reload partner place profile",
          polo_id: socket.assigns.current_polo.id,
          polo_place_id: polo_place_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated profile could not be reloaded."))
         |> redirect(to: places_path(socket.assigns.current_polo.slug))}
    end
  end

  defp load_place_data(scope, polo_place_id) do
    with {:ok, place} <- Directory.get_partner_place(scope, polo_place_id),
         {:ok, categories} <- Directory.list_partner_place_categories(scope) do
      {:ok, place, categories}
    end
  end

  defp assign_place(socket, place) do
    profile_form_data = PlaceProfileForm.from_place(place, profile_idempotency_key())

    socket
    |> assign(:place, place)
    |> assign(:profile_form_data, profile_form_data)
    |> assign(:profile_form, to_form(PlaceProfileForm.change(profile_form_data), as: :profile))
    |> assign(
      :profile_category_options,
      profile_category_options(place, socket.assigns.place_categories)
    )
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

  defp refresh_partner(socket) do
    with {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, partner_access} <- PartnerAuth.authorize(account_scope),
         %{} = polo <-
           Enum.find(partner_access.polos, &(&1.id == socket.assigns.current_polo.id)) do
      {:ok,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:partner_access, partner_access)
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))}
    else
      _invalid_or_revoked -> :error
    end
  end

  defp select_polo(polos, slug) when is_binary(slug) do
    case Enum.find(polos, &(&1.slug == slug)) do
      nil -> :error
      polo -> {:ok, polo}
    end
  end

  defp select_polo(_polos, _slug), do: :error

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp profile_revision(nil), do: 0
  defp profile_revision(profile), do: profile.revision

  defp profile_idempotency_key do
    "partner-place-profile-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp places_path(slug), do: "/partner?#{URI.encode_query(%{"polo" => slug})}"

  defp redirect_invalid_polo(socket) do
    fallback = List.first(socket.assigns.partner_access.polos)

    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: places_path(fallback.slug))}
  end

  defp redirect_missing(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The place was not found in your current assignments."))
     |> redirect(to: places_path(polo.slug))}
  end

  defp redirect_unauthorized(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your partner access is no longer available."))
     |> redirect(to: "/partner/login")}
  end

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
end
