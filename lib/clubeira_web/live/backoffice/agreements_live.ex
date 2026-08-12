defmodule ClubeiraWeb.Backoffice.AgreementsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Partnerships
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit status)
  @publish_fields ~w(
    agreement_number benefit_offer_version_ids brand_ids edition_ids idempotency_key name
    organization_ids polo_place_ids redemption_sla_seconds settlement_model signed_at valid_from
    valid_until
  )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:agreements, dom_id: &"partner-agreement-#{&1["id"]}")
     |> assign(:page_title, gettext("Partner agreements"))}
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

    {:noreply, push_patch(socket, to: agreements_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/partners/agreements?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The agreement filters were invalid."))}
  end

  def handle_event("publish_agreement", %{"agreement" => params}, socket)
      when is_map(params) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> publish_agreement(Map.take(params, @publish_fields))

      :error ->
        redirect_expired_session(socket)
    end
  end

  def handle_event("publish_agreement", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The agreement publication request was invalid."))}
  end

  defp load_workspace(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)
    query_params = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Partnerships.list_agreements(scope, query_params),
         {:ok, options} <- Partnerships.list_agreement_options(scope) do
      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(
         :filter_form,
         to_form(%{"status" => Map.get(params, "status", "")}, as: :filters)
       )
       |> assign(:options, options)
       |> assign(:publish_form, new_publish_form())
       |> assign_result(polo, query_params, params, result)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} when reason in [:invalid_partner_agreement_status, :invalid_pagination] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The agreement filters were invalid and have been cleared.")
         )
         |> redirect(to: agreements_path(polo.slug))}

      {:error, reason} ->
        Logger.error("could not load partner-agreement workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The partner agreement workspace is temporarily unavailable.")
         )
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp publish_agreement(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Partnerships.publish_agreement(scope, params) do
      {:ok, _result} ->
        refresh_inventory(socket, gettext("The partner agreement was published successfully."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:publish_form, to_form(changeset, as: :agreement))
         |> put_flash(:error, gettext("Review the agreement data before publishing."))}

      {:error, reason}
      when reason in [
             :agreement_number_taken,
             :idempotency_conflict,
             :request_in_progress
           ] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This agreement conflicts with another publication. Review and retry.")
         )}

      {:error, reason}
      when reason in [
             :benefit_offer_version_not_found,
             :brand_not_authorized,
             :edition_not_found,
             :organization_not_found,
             :polo_place_not_authorized
           ] ->
        refresh_workspace(
          socket,
          gettext("A selected agreement reference is no longer available. Review the options."),
          :error
        )

      {:error, :invalid_signed_at} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "The signature time must be within the agreement validity and not in the future."
           )
         )}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not publish partner agreement from backoffice",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The partner agreement could not be published."))}
    end
  end

  defp refresh_inventory(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Partnerships.list_agreements(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:publish_form, new_publish_form())
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
        Logger.error("could not reload partner-agreement inventory",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated agreement inventory could not be reloaded."))
         |> redirect(to: agreements_path(socket.assigns.current_polo.slug))}
    end
  end

  defp refresh_workspace(socket, message, flash_kind) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Partnerships.list_agreement_options(scope) do
      {:ok, options} ->
        socket
        |> assign(:options, options)
        |> refresh_inventory(message, flash_kind)

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload partner-agreement options",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The agreement options could not be reloaded."))
         |> redirect(to: agreements_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_result(socket, polo, query_params, path_params, result) do
    socket
    |> assign(:query_params, query_params)
    |> assign(:limit_param, Map.get(path_params, "limit"))
    |> assign(:next_page_path, next_page_path(polo, path_params, result.page))
    |> assign(:page, result.page)
    |> stream(:agreements, result.agreements, reset: true)
  end

  defp new_publish_form do
    now = DateTime.utc_now(:second)

    %{
      "valid_from" => DateTime.add(now, -60),
      "valid_until" => DateTime.add(now, 365 * 86_400),
      "signed_at" => now,
      "settlement_model" => "none",
      "redemption_sla_seconds" => 30,
      "idempotency_key" => "agreement-publication-#{uuid7()}"
    }
    |> Partnerships.change_agreement_publish_request()
    |> to_form(as: :agreement)
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
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/partners/agreements?#{query}"
  end

  defp agreements_path(polo_slug), do: ~p"/admin/partners/agreements?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage partner agreements."))
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
  defp status_label("draft"), do: gettext("Draft")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("terminated"), do: gettext("Terminated")

  defp settlement_label("fixed"), do: gettext("Fixed")
  defp settlement_label("none"), do: gettext("No settlement")
  defp settlement_label("revenue_share"), do: gettext("Revenue share")
  defp settlement_label(_model), do: gettext("Unknown")
end
