defmodule ClubeiraWeb.Backoffice.PartnersLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after email limit status)
  @onboarding_fields ~w(
    cnpj complement district idempotency_key legal_name number place_name place_slug postal_code
    street trade_name
  )
  @grant_fields ~w(email idempotency_key)
  @revocation_fields ~w(reason idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:partner_accesses, dom_id: &"partner-access-#{&1.id}")
     |> assign(:page_title, gettext("Partner network"))}
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

    {:noreply, push_patch(socket, to: partners_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:email, filters["email"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/partners?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The partner access filters were invalid."))}
  end

  def handle_event("onboard_partner", %{"onboarding" => params}, socket) when is_map(params) do
    with_refreshed_scope(socket, fn socket ->
      onboard_partner(socket, Map.take(params, @onboarding_fields))
    end)
  end

  def handle_event("onboard_partner", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The partner onboarding request was invalid."))}
  end

  def handle_event(
        "grant_partner_access",
        %{"place_id" => place_id, "partner_access" => params},
        socket
      )
      when is_binary(place_id) and is_map(params) do
    if available_place?(socket.assigns.available_places, place_id) do
      with_refreshed_scope(socket, fn socket ->
        grant_partner_access(socket, place_id, Map.take(params, @grant_fields))
      end)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("The selected place is not available for partner access.")
       )}
    end
  end

  def handle_event("grant_partner_access", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The partner access request was invalid."))}
  end

  def handle_event(
        "revoke_partner_access",
        %{"access_id" => access_id, "revocation" => params},
        socket
      )
      when is_binary(access_id) and is_map(params) do
    if Map.has_key?(socket.assigns.revocation_forms, access_id) do
      with_refreshed_scope(socket, fn socket ->
        revoke_partner_access(socket, access_id, Map.take(params, @revocation_fields))
      end)
    else
      {:noreply,
       put_flash(socket, :error, gettext("The partner access is not available for revocation."))}
    end
  end

  def handle_event("revoke_partner_access", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The partner revocation request was invalid."))}
  end

  defp load_workspace(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)
    query_params = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Directory.list_backoffice_partner_accesses(scope, query_params),
         {:ok, %{places: places}} <-
           Directory.list_backoffice_places(scope, %{"status" => "active", "limit" => "100"}) do
      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(
         :filter_form,
         to_form(
           %{"status" => Map.get(params, "status", ""), "email" => Map.get(params, "email", "")},
           as: :filters
         )
       )
       |> assign(:available_places, places)
       |> assign(:onboarding_form, new_onboarding_form())
       |> assign(:grant_form, new_grant_form())
       |> assign_result(polo, query_params, params, result)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason}
      when reason in [
             :invalid_pagination,
             :invalid_partner_access_email,
             :invalid_partner_access_status
           ] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The partner access filters were invalid and have been cleared.")
         )
         |> redirect(to: partners_path(polo.slug))}

      {:error, reason} ->
        Logger.error("could not load partner workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The partner workspace is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp onboard_partner(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Directory.onboard_partner(scope, onboarding_attributes(params)) do
      {:ok, _result} ->
        refresh_workspace(socket, gettext("The partner and its first place were created."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:onboarding_form, to_form(changeset, as: :onboarding))
         |> put_flash(:error, gettext("Review the partner and place data before submitting."))}

      {:error, reason}
      when reason in [
             :cnpj_already_registered,
             :idempotency_conflict,
             :place_slug_taken,
             :request_in_progress
           ] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This partner onboarding conflicts with existing or concurrent data.")
         )}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not onboard partner from backoffice",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("The partner could not be onboarded."))}
    end
  end

  defp grant_partner_access(socket, place_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Directory.grant_partner_access(scope, place_id, params) do
      {:ok, _result} ->
        refresh_accesses(socket, gettext("Partner access was granted."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:grant_form, to_form(changeset, as: :partner_access))
         |> put_flash(:error, gettext("Review the partner account before granting access."))}

      {:error, :partner_user_not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No verified active account was found for this email.")
         )}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :partner_user_has_polo_access,
             :request_in_progress
           ] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This account already has or is receiving polo access.")
         )}

      {:error, reason} when reason in [:place_not_found, :partner_role_unavailable] ->
        refresh_workspace(
          socket,
          gettext("The selected place or partner role is no longer available."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not grant partner access from backoffice",
          polo_id: socket.assigns.current_polo.id,
          place_id: place_id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("Partner access could not be granted."))}
    end
  end

  defp revoke_partner_access(socket, access_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Directory.revoke_partner_access(scope, access_id, params) do
      {:ok, _result} ->
        refresh_accesses(socket, gettext("Partner access was revoked."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :revocation_forms,
           Map.put(
             socket.assigns.revocation_forms,
             access_id,
             to_form(changeset, as: :revocation)
           )
         )
         |> put_flash(:error, gettext("Review the revocation reason before submitting."))}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :partner_access_not_found,
             :partner_access_revoked,
             :partner_access_unavailable,
             :request_in_progress
           ] ->
        refresh_accesses(
          socket,
          gettext("The partner access changed before this revocation completed."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not revoke partner access from backoffice",
          polo_id: socket.assigns.current_polo.id,
          access_id: access_id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("Partner access could not be revoked."))}
    end
  end

  defp refresh_workspace(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    with {:ok, result} <-
           Directory.list_backoffice_partner_accesses(scope, socket.assigns.query_params),
         {:ok, %{places: places}} <-
           Directory.list_backoffice_places(scope, %{"status" => "active", "limit" => "100"}) do
      {:noreply,
       socket
       |> assign(:available_places, places)
       |> assign(:onboarding_form, new_onboarding_form())
       |> assign(:grant_form, new_grant_form())
       |> assign_result(
         socket.assigns.current_polo,
         socket.assigns.query_params,
         socket.assigns.query_params,
         result
       )
       |> put_flash(flash_kind, message)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload partner workspace",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated partner workspace could not be reloaded."))
         |> redirect(to: partners_path(socket.assigns.current_polo.slug))}
    end
  end

  defp refresh_accesses(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Directory.list_backoffice_partner_accesses(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:grant_form, new_grant_form())
         |> assign_result(
           socket.assigns.current_polo,
           socket.assigns.query_params,
           socket.assigns.query_params,
           result
         )
         |> put_flash(flash_kind, message)}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload partner accesses",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The updated partner access inventory could not be reloaded.")
         )
         |> redirect(to: partners_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_result(socket, polo, query_params, path_params, result) do
    revocation_forms =
      result.partner_accesses
      |> Enum.filter(&(&1.status == "active"))
      |> Map.new(&{&1.id, new_revocation_form()})

    socket
    |> assign(:query_params, query_params)
    |> assign(:limit_param, Map.get(path_params, "limit"))
    |> assign(:next_page_path, next_page_path(polo, path_params, result.page))
    |> assign(:revocation_forms, revocation_forms)
    |> assign(:page, result.page)
    |> stream(:partner_accesses, result.partner_accesses, reset: true)
  end

  defp onboarding_attributes(params) do
    %{
      "organization" => Map.take(params, ~w(legal_name trade_name cnpj)),
      "place" =>
        params
        |> then(&%{"name" => &1["place_name"], "slug" => &1["place_slug"]})
        |> Map.put("address", Map.take(params, ~w(postal_code street number complement district))),
      "idempotency_key" => params["idempotency_key"]
    }
  end

  defp new_onboarding_form do
    %{"idempotency_key" => "partner-onboarding-#{uuid7()}"}
    |> Directory.change_partner_onboarding_request()
    |> to_form(as: :onboarding)
  end

  defp new_grant_form do
    %{"idempotency_key" => "partner-access-grant-#{uuid7()}"}
    |> Directory.change_partner_access_grant_request()
    |> to_form(as: :partner_access)
  end

  defp new_revocation_form do
    %{"idempotency_key" => "partner-access-revoke-#{uuid7()}"}
    |> Directory.change_partner_access_revocation_request()
    |> to_form(as: :revocation)
  end

  defp available_place?(places, place_id), do: Enum.any?(places, &(&1.place.id == place_id))

  defp with_refreshed_scope(socket, callback) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> callback.(assign(socket, :current_account_scope, account_scope))
      :error -> redirect_expired_session(socket)
    end
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
      |> maybe_put_filter(:email, params["email"])
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/partners?#{query}"
  end

  defp partners_path(polo_slug), do: ~p"/admin/partners?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage partners."))
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
  defp status_label("invited"), do: gettext("Invited")
  defp status_label("revoked"), do: gettext("Revoked")
  defp status_label("suspended"), do: gettext("Suspended")
end
