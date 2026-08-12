defmodule ClubeiraWeb.Member.CatalogLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Catalog
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.MemberComponents

  @page_limit "20"
  @query_fields ~w(after limit)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:offers, dom_id: &"catalog-offer-#{&1.offer_version_id}")
     |> stream_configure(:checkout_options, dom_id: &"checkout-option-#{&1.offering_price_id}")
     |> assign(:page_title, gettext("Explore Clubeira"))
     |> assign(:checkout_result, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, polo_page} <- Polos.list_public(%{"limit" => "100"}),
         {:ok, polo} <- select_polo(polo_page.polos, params["polo"]),
         {:ok, catalog} <- Catalog.fetch_public(polo.slug, catalog_params(params)),
         {:ok, checkout} <- Catalog.fetch_checkout_options(polo.slug, %{"limit" => "100"}) do
      checkout_options = Enum.filter(checkout.options, &web_checkout_available?/1)
      option_index = Map.new(checkout_options, &{&1.offering_price_id, &1})

      {:noreply,
       socket
       |> assign(:polos, polo_page.polos)
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :catalog))
       |> assign(:checkout_option_index, option_index)
       |> assign(:checkout_keys, checkout_keys(option_index))
       |> assign(:next_page_path, next_page_path(polo, params, catalog.page))
       |> assign(:checkout_result, nil)
       |> stream(:offers, catalog.offers, reset: true)
       |> stream(:checkout_options, checkout_options, reset: true)}
    else
      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The catalog page was invalid and has been reset."))
         |> redirect(to: ~p"/app/catalog")}

      {:error, :polo_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No active Clubeira polo is available right now."))
         |> redirect(to: ~p"/app")}

      {:error, reason} ->
        Logger.error("could not load member catalog", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("The catalog is temporarily unavailable."))
         |> redirect(to: ~p"/app")}
    end
  end

  @impl true
  def handle_event("change_catalog_polo", %{"catalog" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    selected = Enum.find(socket.assigns.polos, &(&1.slug == slug)) || socket.assigns.current_polo
    {:noreply, push_patch(socket, to: ~p"/app/catalog?#{[polo: selected.slug]}")}
  end

  def handle_event("change_catalog_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("checkout", %{"price-id" => price_id}, socket) when is_binary(price_id) do
    case Map.fetch(socket.assigns.checkout_option_index, price_id) do
      {:ok, option} ->
        refresh_and_checkout(socket, option)

      :error ->
        {:noreply, put_flash(socket, :error, gettext("This offer is no longer available."))}
    end
  end

  def handle_event("checkout", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The checkout request was invalid."))}
  end

  defp refresh_and_checkout(socket, option) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> place_and_start(option)

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}
    end
  end

  defp place_and_start(socket, option) do
    scope = member_scope(socket)
    idempotency_key = Map.fetch!(socket.assigns.checkout_keys, option.offering_price_id)

    attributes = %{
      "product_offering_version_id" => option.product_offering_version_id,
      "offering_price_id" => option.offering_price_id,
      "quantity" => 1,
      "idempotency_key" => idempotency_key
    }

    case Billing.place_order(scope, attributes) do
      {:ok, order} ->
        start_checkout(socket, scope, option, order)

      {:error, %Ecto.Changeset{}} ->
        checkout_error(socket, gettext("Review the selected offer."))

      {:error, :idempotency_conflict} ->
        checkout_error(socket, gettext("This checkout changed before it completed."))

      {:error, :request_in_progress} ->
        checkout_error(socket, gettext("This checkout is already being processed."))

      {:error, reason} ->
        Logger.error("could not place member catalog order",
          polo_id: scope.polo_id,
          price_id: option.offering_price_id,
          reason: inspect(reason)
        )

        checkout_error(socket, gettext("This offer could not be purchased right now."))
    end
  end

  defp start_checkout(socket, scope, _option, order) do
    case Billing.start_payment(scope, %{
           "order_id" => order.id,
           "payment_method" => "pix",
           "idempotency_key" => "payment-#{order.id}"
         }) do
      {:ok, %{payment_intent: intent}} -> finish_pix(socket, order, intent)
      {:error, reason} -> payment_start_error(socket, order, reason)
    end
  end

  defp finish_pix(socket, order, intent) do
    next_action = intent.next_action
    copy_paste_code = value(next_action, :copy_paste_code)
    redirect_url = safe_external_url(value(next_action, :redirect_url))

    if is_binary(copy_paste_code) and copy_paste_code != "" do
      {:noreply,
       socket
       |> assign(:checkout_result, %{
         kind: :pix,
         order: order,
         amount: intent.amount,
         currency: intent.currency,
         copy_paste_code: copy_paste_code,
         redirect_url: redirect_url,
         expires_at: intent.expires_at
       })
       |> rotate_checkout_key(intent.order_id)
       |> put_flash(:info, gettext("Your order was created. Complete the Pix payment."))}
    else
      checkout_created_without_action(socket, order)
    end
  end

  defp payment_start_error(socket, order, reason) do
    Logger.warning("member order created but payment could not start",
      order_id: order.id,
      reason: inspect(reason)
    )

    {:noreply,
     socket
     |> assign(:checkout_result, %{kind: :pending, order: order})
     |> put_flash(
       :error,
       gettext("Your order was created, but payment could not start. Retry from your orders.")
     )}
  end

  defp checkout_created_without_action(socket, order) do
    {:noreply,
     socket
     |> assign(:checkout_result, %{kind: :pending, order: order})
     |> put_flash(:info, gettext("Your order was created and is awaiting payment."))}
  end

  defp checkout_error(socket, message), do: {:noreply, put_flash(socket, :error, message)}

  defp member_scope(socket) do
    account_scope = socket.assigns.current_account_scope

    Scope.new!(socket.assigns.current_polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp catalog_params(params) do
    params
    |> Map.take(@query_fields)
    |> Map.put_new("limit", @page_limit)
  end

  defp select_polo([], _slug), do: {:error, :polo_not_found}

  defp select_polo(polos, slug) do
    {:ok, Enum.find(polos, &(&1.slug == slug)) || List.first(polos)}
  end

  defp checkout_keys(option_index) do
    Map.new(option_index, fn {price_id, _option} ->
      {price_id, "checkout-#{uuid7()}"}
    end)
  end

  defp rotate_checkout_key(socket, _order_id) do
    assign(socket, :checkout_keys, checkout_keys(socket.assigns.checkout_option_index))
  end

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query =
      [polo: polo.slug, after: page.next_cursor]
      |> maybe_put(:limit, params["limit"])

    ~p"/app/catalog?#{query}"
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

  # Automatic renewal stays outside the browser until members can cancel it
  # through the same authenticated, provider-synchronized product boundary.
  defp web_checkout_available?(%{renewal_policy: "none"}), do: true
  defp web_checkout_available?(_option), do: false

  defp money(amount, currency, locale) do
    decimal = amount |> Decimal.round(2) |> Decimal.to_string(:normal)
    localized = if locale == "pt_BR", do: String.replace(decimal, ".", ","), else: decimal
    "#{currency} #{localized}"
  end

  defp benefit_value(%{benefit_kind: "discount_percentage", percentage_value: value}),
    do: gettext("%{value}% off", value: Decimal.to_string(value, :normal))

  defp benefit_value(%{benefit_kind: "discount_amount", amount_value: value, currency: currency}),
    do:
      gettext("%{currency} %{value} off",
        currency: currency,
        value: Decimal.to_string(value, :normal)
      )

  defp benefit_value(_offer), do: gettext("Exclusive benefit")

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
