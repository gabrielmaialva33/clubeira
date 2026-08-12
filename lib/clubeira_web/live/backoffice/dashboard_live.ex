defmodule ClubeiraWeb.Backoffice.DashboardLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Billing
  alias Clubeira.Directory
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @preview_params %{"limit" => "5"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:places, dom_id: &"place-#{&1.id}")
     |> stream_configure(:payments, dom_id: &"payment-#{&1.id}")
     |> stream_configure(:subscriptions, dom_id: &"subscription-#{&1.id}")
     |> assign(:page_title, gettext("Overview"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])
    tenant_scope = tenant_scope(socket.assigns.current_account_scope, polo)
    dashboard = load_dashboard(tenant_scope, polo.capabilities)

    {:noreply,
     socket
     |> assign(:current_polo, polo)
     |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
     |> assign(:preview_counts, dashboard.counts)
     |> assign(:load_errors, dashboard.errors)
     |> stream(:places, dashboard.places, reset: true)
     |> stream(:payments, dashboard.payments, reset: true)
     |> stream(:subscriptions, dashboard.subscriptions, reset: true)}
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp select_polo(polos, slug) do
    Enum.find(polos, &(&1.slug == slug)) || List.first(polos)
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp load_dashboard(scope, capabilities) do
    {places, places_error} =
      read_section(
        :manage_partners in capabilities,
        :places,
        scope,
        fn -> Directory.list_backoffice_places(scope, @preview_params) end
      )

    {payments, payments_error} =
      read_section(
        :manage_billing in capabilities,
        :payments,
        scope,
        fn -> Billing.list_backoffice_payments(scope, @preview_params) end
      )

    {subscriptions, subscriptions_error} =
      read_section(
        :manage_billing in capabilities,
        :subscriptions,
        scope,
        fn -> Subscriptions.list_backoffice_subscriptions(scope, @preview_params) end
      )

    %{
      places: places,
      payments: payments,
      subscriptions: subscriptions,
      counts: %{
        places: length(places),
        payments: length(payments),
        subscriptions: length(subscriptions)
      },
      errors: Enum.reject([places_error, payments_error, subscriptions_error], &is_nil/1)
    }
  end

  defp read_section(false, _key, _scope, _reader), do: {[], nil}

  defp read_section(true, key, scope, reader) do
    case reader.() do
      {:ok, result} ->
        {Map.fetch!(result, key), nil}

      {:error, reason} ->
        Logger.error("could not load backoffice dashboard section",
          section: key,
          polo_id: scope.polo_id,
          reason: inspect(reason)
        )

        {[], key}
    end
  end

  defp capability?(polo, capability), do: capability in polo.capabilities

  defp money(amount, currency, locale) do
    normalized =
      amount
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> localize_decimal_separator(locale)

    "#{currency} #{normalized}"
  end

  defp localize_decimal_separator(value, "en"), do: value
  defp localize_decimal_separator(value, "pt_BR"), do: String.replace(value, ".", ",")

  defp timestamp(nil, _locale), do: gettext("Not available")

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("captured"), do: gettext("Captured")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("past_due"), do: gettext("Past due")
  defp status_label("authorized"), do: gettext("Authorized")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("refunded"), do: gettext("Refunded")
  defp status_label("charged_back"), do: gettext("Charged back")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label("invited"), do: gettext("Invited")
  defp status_label("retired"), do: gettext("Retired")
  defp status_label(status), do: String.replace(status, "_", " ")

  defp status_class(status) when status in ["active", "captured"] do
    "bg-emerald-50 text-emerald-700 ring-emerald-600/10"
  end

  defp status_class(status) when status in ["pending", "past_due"] do
    "bg-amber-50 text-amber-700 ring-amber-600/10"
  end

  defp status_class(status) when status in ["suspended", "failed", "cancelled", "charged_back"] do
    "bg-red-50 text-red-700 ring-red-600/10"
  end

  defp status_class(status) when status in ["authorized", "refunded"] do
    "bg-blue-50 text-blue-700 ring-blue-600/10"
  end

  defp status_class(_status), do: "bg-slate-100 text-slate-600 ring-slate-500/10"
end
