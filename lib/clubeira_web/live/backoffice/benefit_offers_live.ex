defmodule ClubeiraWeb.Backoffice.BenefitOffersLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Catalog
  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after code limit status)
  @publish_fields ~w(
    code name benefit_kind title description terms redemption_instructions percentage_value
    amount_value currency effective_from effective_until idempotency_key
  )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:benefit_offers, dom_id: &"benefit-offer-#{&1.id}")
     |> assign(:page_title, gettext("Commercial catalog"))}
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

    {:noreply, push_patch(socket, to: benefits_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:code, filters["code"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/commercial/benefits?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The benefit filters were invalid."))}
  end

  def handle_event("select_benefit_place", %{"place" => %{"id" => place_id}}, socket)
      when is_binary(place_id) do
    selected = Enum.find(socket.assigns.available_places, &(&1.place.id == place_id))

    if selected do
      {:noreply, assign_selected_place(socket, selected)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("The selected place is not available for publication."))}
    end
  end

  def handle_event("select_benefit_place", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The selected place is not available for publication."))}
  end

  def handle_event("publish_benefit_offer", %{"benefit_offer" => params}, socket)
      when is_map(params) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> publish_benefit(params)

      :error ->
        redirect_expired_session(socket)
    end
  end

  def handle_event("publish_benefit_offer", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The benefit publication request was invalid."))}
  end

  defp load_workspace(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Catalog.list_benefit_offers(scope, query_params),
         {:ok, %{places: places}} <-
           Directory.list_backoffice_places(scope, %{"status" => "active", "limit" => "100"}) do
      selected_place = select_place(places, params["place"])

      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(
         :filter_form,
         to_form(
           %{"status" => Map.get(params, "status", ""), "code" => Map.get(params, "code", "")},
           as: :filters
         )
       )
       |> assign(:available_places, places)
       |> assign_selected_place(selected_place)
       |> assign(:publish_form, new_publish_form())
       |> assign(:query_params, query_params)
       |> assign(:limit_param, Map.get(params, "limit"))
       |> assign(:next_page_path, next_page_path(polo, params, result.page))
       |> assign(:page, result.page)
       |> stream(:benefit_offers, result.benefit_offers, reset: true)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason}
      when reason in [
             :invalid_benefit_offer_code,
             :invalid_benefit_offer_status,
             :invalid_pagination,
             :invalid_place_id
           ] ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The benefit filters were invalid and have been cleared."))
         |> redirect(to: benefits_path(polo.slug))}

      {:error, reason} ->
        Logger.error("could not load benefit-offer workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The commercial catalog is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp publish_benefit(%{assigns: %{selected_place: nil}} = socket, _params) do
    {:noreply, put_flash(socket, :error, gettext("Select an active place before publishing."))}
  end

  defp publish_benefit(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    attributes = publication_attributes(Map.take(params, @publish_fields))

    case Catalog.publish_benefit_offer(
           scope,
           socket.assigns.selected_place.place.id,
           attributes
         ) do
      {:ok, _result} ->
        refresh_after_publication(socket)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:publish_form, to_form(changeset, as: :benefit_offer))
         |> put_flash(:error, gettext("Review the benefit data before publishing."))}

      {:error, reason}
      when reason in [:idempotency_conflict, :offer_code_taken, :request_in_progress] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This benefit publication conflicts with another request. Review and retry.")
         )}

      {:error, reason} when reason in [:partner_admin_required, :place_not_found] ->
        refresh_or_redirect_unauthorized(socket, reason)

      {:error, reason} ->
        Logger.error("could not publish benefit offer from backoffice",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("The benefit could not be published."))}
    end
  end

  defp refresh_after_publication(socket) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Catalog.list_benefit_offers(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:publish_form, new_publish_form())
         |> assign(
           :next_page_path,
           next_page_path(socket.assigns.current_polo, socket.assigns.query_params, result.page)
         )
         |> assign(:page, result.page)
         |> stream(:benefit_offers, result.benefit_offers, reset: true)
         |> put_flash(:info, gettext("The benefit was published successfully."))}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload benefit-offer inventory",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated benefit inventory could not be reloaded."))
         |> redirect(to: benefits_path(socket.assigns.current_polo.slug))}
    end
  end

  defp publication_attributes(params) do
    %{
      "offer" => Map.take(params, ~w(code name benefit_kind)),
      "version" =>
        params
        |> Map.take(
          ~w(title description terms redemption_instructions percentage_value amount_value currency)
        )
        |> Map.put("effective_during", %{
          "starts_at" => params["effective_from"],
          "ends_at" => params["effective_until"]
        }),
      "idempotency_key" => params["idempotency_key"]
    }
  end

  defp new_publish_form do
    %{
      "effective_from" => DateTime.utc_now(),
      "idempotency_key" => "benefit-publication-#{uuid7()}"
    }
    |> Catalog.change_benefit_offer_publish_request()
    |> to_form(as: :benefit_offer)
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
      |> maybe_put_filter(:code, params["code"])
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/commercial/benefits?#{query}"
  end

  defp benefits_path(polo_slug), do: ~p"/admin/commercial/benefits?#{[polo: polo_slug]}"

  defp refresh_or_redirect_unauthorized(socket, :partner_admin_required),
    do: redirect_unauthorized(socket, socket.assigns.current_polo)

  defp refresh_or_redirect_unauthorized(socket, :place_not_found) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected place is no longer active."))
     |> redirect(to: benefits_path(socket.assigns.current_polo.slug))}
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage the commercial catalog."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp benefit_value(%{percentage_value: %Decimal{} = value}),
    do: gettext("%{value}% discount", value: Decimal.to_string(value, :normal))

  defp benefit_value(%{amount_value: %Decimal{} = value, currency: currency}),
    do: "#{currency} #{Decimal.to_string(value, :normal)}"

  defp benefit_value(_version), do: gettext("Custom benefit")

  defp status_label("active"), do: gettext("Active")
  defp status_label("draft"), do: gettext("Draft")
  defp status_label("retired"), do: gettext("Retired")
end
