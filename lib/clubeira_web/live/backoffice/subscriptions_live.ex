defmodule ClubeiraWeb.Backoffice.SubscriptionsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit order_number status)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:subscriptions, dom_id: &"subscription-#{&1.id}")
     |> assign(:page_title, gettext("Subscriptions"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_billing in polo.capabilities do
      load_subscriptions(socket, polo, params)
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

    {:noreply, push_patch(socket, to: subscriptions_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:order_number, filters["order_number"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/subscriptions?#{query}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The subscription filters were invalid."))}
  end

  defp load_subscriptions(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Subscriptions.list_backoffice_subscriptions(scope, query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:current_polo, polo)
         |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
         |> assign(
           :filter_form,
           to_form(
             %{
               "status" => Map.get(params, "status", ""),
               "order_number" => Map.get(params, "order_number", "")
             },
             as: :filters
           )
         )
         |> assign(:limit_param, Map.get(params, "limit"))
         |> assign(:next_page_path, next_page_path(polo, params, result.page))
         |> assign(:page, result.page)
         |> stream(:subscriptions, result.subscriptions, reset: true)}

      {:error, reason}
      when reason in [
             :invalid_order_number,
             :invalid_pagination,
             :invalid_subscription_filter,
             :invalid_subscription_status
           ] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The subscription filters were invalid and have been cleared.")
         )
         |> redirect(to: subscriptions_path(polo.slug))}

      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} ->
        Logger.error("could not load backoffice subscription inventory",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The subscription inventory is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
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
      |> maybe_put_filter(:order_number, params["order_number"])
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/subscriptions?#{query}"
  end

  defp subscriptions_path(polo_slug), do: ~p"/admin/subscriptions?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to the subscription inventory."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp timestamp(nil, _locale), do: gettext("Not available")

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end

  defp status_label("pending"), do: gettext("Pending")
  defp status_label("active"), do: gettext("Active")
  defp status_label("past_due"), do: gettext("Past due")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("expired"), do: gettext("Expired")

  defp status_class("active"), do: "bg-emerald-50 text-emerald-700 ring-emerald-600/10"

  defp status_class(status) when status in ["pending", "past_due"],
    do: "bg-amber-50 text-amber-700 ring-amber-600/10"

  defp status_class(status) when status in ["suspended", "cancelled"],
    do: "bg-red-50 text-red-700 ring-red-600/10"

  defp status_class(_status), do: "bg-slate-100 text-slate-600 ring-slate-500/10"
end
