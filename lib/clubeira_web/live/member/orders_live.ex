defmodule ClubeiraWeb.Member.OrdersLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.MemberComponents

  @page_limit "20"
  @query_fields ~w(after limit)
  @payable_statuses ~w(pending awaiting_payment)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:orders, dom_id: &"member-order-#{&1.id}")
     |> assign(:page_title, gettext("My orders"))
     |> assign(:payment_result, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, polo_page} <- Polos.list_public(%{"limit" => "100"}),
         {:ok, subscriptions} <-
           Subscriptions.list_for_account(socket.assigns.current_account_scope),
         polos = available_polos(polo_page.polos, subscriptions),
         {:ok, polo} <- select_polo(polos, params["polo"]),
         {:ok, result} <- Billing.list_orders(scope(socket, polo), order_params(params)) do
      {:noreply,
       socket
       |> assign(:polos, polos)
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :orders))
       |> assign(:order_index, Map.new(result.orders, &{&1.id, &1}))
       |> assign(:next_page_path, next_page_path(polo, params, result.page))
       |> assign(:payment_result, nil)
       |> stream(:orders, result.orders, reset: true)}
    else
      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The orders page was invalid and has been reset."))
         |> redirect(to: ~p"/app/orders")}

      {:error, :polo_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No active Clubeira polo is available right now."))
         |> redirect(to: ~p"/app")}

      {:error, reason} ->
        Logger.error("could not load member orders", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("Your orders are temporarily unavailable."))
         |> redirect(to: ~p"/app")}
    end
  end

  @impl true
  def handle_event("change_orders_polo", %{"orders" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    selected = Enum.find(socket.assigns.polos, &(&1.slug == slug)) || socket.assigns.current_polo
    {:noreply, push_patch(socket, to: ~p"/app/orders?#{[polo: selected.slug]}")}
  end

  def handle_event("change_orders_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("pay_order", %{"order-id" => order_id}, socket) when is_binary(order_id) do
    case Map.get(socket.assigns.order_index, order_id) do
      %{status: status} = order when status in @payable_statuses ->
        if web_payment_available?(order) do
          refresh_and_pay(socket, order)
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Automatic renewal payment is not available on the web yet.")
           )}
        end

      _missing_or_terminal ->
        {:noreply, put_flash(socket, :error, gettext("This order is not available for payment."))}
    end
  end

  def handle_event("pay_order", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The payment request was invalid."))}
  end

  defp refresh_and_pay(socket, order) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> start_payment(order)

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}
    end
  end

  defp start_payment(socket, order) do
    case Billing.start_payment(scope(socket, socket.assigns.current_polo), %{
           "order_id" => order.id,
           "payment_method" => "pix",
           "idempotency_key" => "payment-#{order.id}"
         }) do
      {:ok, %{payment_intent: intent}} -> pix_started(socket, order, intent)
      {:error, reason} -> payment_error(socket, order, reason)
    end
  end

  defp pix_started(socket, order, intent) do
    action = intent.next_action
    code = value(action, :copy_paste_code)

    if is_binary(code) and code != "" do
      {:noreply,
       socket
       |> assign(:payment_result, %{
         order: order,
         copy_paste_code: code,
         redirect_url: safe_external_url(value(action, :redirect_url)),
         amount: intent.amount,
         currency: intent.currency
       })
       |> put_flash(:info, gettext("Pix payment ready."))}
    else
      payment_error(socket, order, :payment_action_unavailable)
    end
  end

  defp payment_error(socket, order, reason) do
    Logger.warning("could not resume member order payment",
      order_id: order.id,
      reason: inspect(reason)
    )

    {:noreply,
     put_flash(socket, :error, gettext("Payment could not be started. Please try again."))}
  end

  defp order_params(params) do
    params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)
  end

  defp scope(socket, polo) do
    account_scope = socket.assigns.current_account_scope

    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp select_polo([], _slug), do: {:error, :polo_not_found}

  defp select_polo(polos, slug),
    do: {:ok, Enum.find(polos, &(&1.slug == slug)) || List.first(polos)}

  defp available_polos(public_polos, subscriptions) do
    (public_polos ++ Enum.map(subscriptions, & &1.polo))
    |> Enum.uniq_by(& &1.id)
  end

  defp web_payment_available?(%{items: [_item | _rest] = items}) do
    Enum.all?(items, &(&1.renewal_policy == "none"))
  end

  defp web_payment_available?(_order), do: false

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query = [polo: polo.slug, after: page.next_cursor] |> maybe_put(:limit, params["limit"])
    ~p"/app/orders?#{query}"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: query ++ [{key, value}]

  defp value(map, key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp safe_external_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> url
      _invalid -> nil
    end
  end

  defp safe_external_url(_url), do: nil

  defp money(amount, currency, locale) do
    value = amount |> Decimal.round(2) |> Decimal.to_string(:normal)
    localized = if locale == "pt_BR", do: String.replace(value, ".", ","), else: value
    "#{currency} #{localized}"
  end

  defp status_label("awaiting_payment"), do: gettext("Awaiting payment")
  defp status_label("paid"), do: gettext("Paid")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label(status), do: String.replace(status, "_", " ")

  defp timestamp(nil, _locale), do: gettext("Not available")
  defp timestamp(value, "pt_BR"), do: Calendar.strftime(value, "%d/%m/%Y · %H:%M")
  defp timestamp(value, _locale), do: Calendar.strftime(value, "%Y-%m-%d · %H:%M")
end
