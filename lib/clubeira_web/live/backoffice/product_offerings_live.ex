defmodule ClubeiraWeb.Backoffice.ProductOfferingsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Catalog
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after code limit status)
  @publish_fields ~w(
    amount benefits code currency cycle_interval_count cycle_interval_unit cycle_policy
    description effective_from effective_until idempotency_key name renewal_policy
  )
  @lifecycle_fields ~w(action reason idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:product_offerings, dom_id: &"product-offering-#{&1.id}")
     |> assign(:page_title, gettext("Subscription offerings"))}
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

    {:noreply, push_patch(socket, to: offerings_path(polo.slug))}
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

    {:noreply, push_patch(socket, to: ~p"/admin/commercial/offerings?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The offering filters were invalid."))}
  end

  def handle_event("validate_product_offering", %{"product_offering" => params}, socket)
      when is_map(params) do
    form =
      params
      |> normalize_benefit_params()
      |> Subscriptions.change_product_offering_publish_request()
      |> Map.put(:action, :validate)
      |> to_form(as: :product_offering)

    {:noreply, assign(socket, :publish_form, form)}
  end

  def handle_event("validate_product_offering", _params, socket), do: {:noreply, socket}

  def handle_event("publish_product_offering", %{"product_offering" => params}, socket)
      when is_map(params) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> publish_offering(params)

      :error ->
        redirect_expired_session(socket)
    end
  end

  def handle_event("publish_product_offering", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The offering publication request was invalid."))}
  end

  def handle_event(
        "transition_product_offering",
        %{"offering_id" => offering_id, "lifecycle" => params},
        socket
      )
      when is_binary(offering_id) and is_map(params) do
    if Map.has_key?(socket.assigns.lifecycle_forms, offering_id) do
      case Accounts.refresh_scope(socket.assigns.current_account_scope) do
        {:ok, account_scope} ->
          socket
          |> assign(:current_account_scope, account_scope)
          |> transition_offering(offering_id, params)

        :error ->
          redirect_expired_session(socket)
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("The offering is not available for this transition."))}
    end
  end

  def handle_event("transition_product_offering", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The lifecycle request was invalid."))}
  end

  defp load_workspace(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)
    query_params = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Subscriptions.list_product_offerings(scope, query_params),
         {:ok, %{benefit_offers: benefit_offers}} <-
           Catalog.list_benefit_offers(scope, %{"status" => "active", "limit" => "100"}) do
      benefit_options = published_benefit_options(benefit_offers)

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
       |> assign(:benefit_options, benefit_options)
       |> assign(:publish_form, new_publish_form(benefit_options))
       |> assign_result(polo, query_params, params, result)}
    else
      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason}
      when reason in [
             :invalid_benefit_offer_status,
             :invalid_pagination,
             :invalid_product_offering_code,
             :invalid_product_offering_status
           ] ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The offering filters were invalid and have been cleared."))
         |> redirect(to: offerings_path(polo.slug))}

      {:error, reason} ->
        Logger.error("could not load product-offering workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The offering workspace is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp publish_offering(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    attributes = params |> Map.take(@publish_fields) |> publication_attributes()

    case Subscriptions.publish_product_offering(scope, attributes) do
      {:ok, _result} ->
        refresh_inventory(socket, gettext("The offering was published successfully."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:publish_form, to_form(changeset, as: :product_offering))
         |> put_flash(:error, gettext("Review the offering data before publishing."))}

      {:error, reason}
      when reason in [
             :benefit_configuration_unavailable,
             :idempotency_conflict,
             :product_offering_code_taken,
             :request_in_progress
           ] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This offering conflicts with the current catalog. Review and retry.")
         )}

      {:error, :benefit_offer_version_not_found} ->
        refresh_inventory(
          socket,
          gettext("A selected benefit is no longer available. Review the catalog."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not publish product offering from backoffice",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("The offering could not be published."))}
    end
  end

  defp transition_offering(socket, offering_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    attributes = Map.take(params, @lifecycle_fields)

    case Subscriptions.transition_product_offering(scope, offering_id, attributes) do
      {:ok, _result} ->
        refresh_inventory(socket, gettext("The offering lifecycle was updated."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :lifecycle_forms,
           Map.put(
             socket.assigns.lifecycle_forms,
             offering_id,
             to_form(changeset, as: :lifecycle)
           )
         )
         |> put_flash(:error, gettext("Review the lifecycle decision before submitting."))}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :invalid_product_offering_transition,
             :product_offering_not_found,
             :request_in_progress
           ] ->
        refresh_inventory(
          socket,
          gettext("The offering changed before this action completed. Review the inventory."),
          :error
        )

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not transition product offering from backoffice",
          polo_id: socket.assigns.current_polo.id,
          offering_id: offering_id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The lifecycle action could not be applied."))}
    end
  end

  defp refresh_inventory(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Subscriptions.list_product_offerings(scope, socket.assigns.query_params) do
      {:ok, result} ->
        params = socket.assigns.query_params

        {:noreply,
         socket
         |> assign(:publish_form, new_publish_form(socket.assigns.benefit_options))
         |> assign_result(socket.assigns.current_polo, params, params, result)
         |> put_flash(flash_kind, message)}

      {:error, :partner_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload product-offering inventory",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated offering inventory could not be reloaded."))
         |> redirect(to: offerings_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_result(socket, polo, query_params, path_params, result) do
    lifecycle_forms =
      result.product_offerings
      |> Enum.filter(&(&1.status in ["active", "paused"]))
      |> Map.new(&{&1.id, lifecycle_form()})

    socket
    |> assign(:query_params, query_params)
    |> assign(:limit_param, Map.get(path_params, "limit"))
    |> assign(:next_page_path, next_page_path(polo, path_params, result.page))
    |> assign(:lifecycle_forms, lifecycle_forms)
    |> assign(:page, result.page)
    |> stream(:product_offerings, result.product_offerings, reset: true)
  end

  defp publication_attributes(params) do
    %{
      "offering" => %{
        "code" => params["code"],
        "name" => params["name"],
        "description" => params["description"],
        "renewal_policy" => params["renewal_policy"],
        "cycle" => %{
          "policy" => params["cycle_policy"],
          "interval_unit" => params["cycle_interval_unit"],
          "interval_count" => params["cycle_interval_count"]
        },
        "effective_during" => %{
          "starts_at" => params["effective_from"],
          "ends_at" => params["effective_until"]
        }
      },
      "price" => %{"currency" => params["currency"], "amount" => params["amount"]},
      "benefits" => benefit_values(params["benefits"]),
      "idempotency_key" => params["idempotency_key"]
    }
  end

  defp normalize_benefit_params(params) do
    Map.update(params, "benefits", [], &benefit_values/1)
  end

  defp benefit_values(benefits) when is_list(benefits), do: benefits

  defp benefit_values(benefits) when is_map(benefits) do
    benefits
    |> Enum.sort_by(fn {index, _benefit} -> index end)
    |> Enum.map(fn {_index, benefit} -> benefit end)
  end

  defp benefit_values(_benefits), do: []

  defp new_publish_form([]) do
    %{
      "effective_from" => DateTime.utc_now(),
      "idempotency_key" => "offering-publication-#{uuid7()}",
      "benefits" => []
    }
    |> Subscriptions.change_product_offering_publish_request()
    |> to_form(as: :product_offering)
  end

  defp new_publish_form([{_label, benefit_version_id} | _options]) do
    %{
      "renewal_policy" => "none",
      "cycle_policy" => "calendar",
      "cycle_interval_unit" => "month",
      "cycle_interval_count" => 1,
      "effective_from" => DateTime.utc_now(),
      "currency" => "BRL",
      "idempotency_key" => "offering-publication-#{uuid7()}",
      "benefits" => [
        %{
          "benefit_offer_version_id" => benefit_version_id,
          "allowance_per_cycle" => 1,
          "consumption_unit" => "per_place"
        }
      ]
    }
    |> Subscriptions.change_product_offering_publish_request()
    |> to_form(as: :product_offering)
  end

  defp lifecycle_form do
    %{"action" => "", "reason" => "", "idempotency_key" => "offering-lifecycle-#{uuid7()}"}
    |> Subscriptions.change_product_offering_lifecycle_request()
    |> to_form(as: :lifecycle)
  end

  defp published_benefit_options(benefit_offers) do
    benefit_offers
    |> Enum.filter(&match?(%{status: "published"}, &1.latest_version))
    |> Enum.map(&{"#{&1.name} · #{&1.latest_version.title}", &1.latest_version.id})
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

    ~p"/admin/commercial/offerings?#{query}"
  end

  defp offerings_path(polo_slug), do: ~p"/admin/commercial/offerings?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage subscription offerings."))
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
  defp status_label("paused"), do: gettext("Paused")
  defp status_label("retired"), do: gettext("Retired")

  defp lifecycle_options("active"),
    do: [{gettext("Pause"), "pause"}, {gettext("Retire"), "retire"}]

  defp lifecycle_options("paused"),
    do: [{gettext("Reactivate"), "reactivate"}, {gettext("Retire"), "retire"}]

  defp lifecycle_options(_status), do: []
end
