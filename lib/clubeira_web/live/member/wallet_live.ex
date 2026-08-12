defmodule ClubeiraWeb.Member.WalletLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Devices
  alias Clubeira.Redemptions
  alias Clubeira.Reviews
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.MemberComponents

  @page_limit "20"
  @query_fields ~w(after limit)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:vouchers, dom_id: &"voucher-#{&1.allocation_id}")
     |> stream_configure(:redemptions, dom_id: &"member-redemption-#{&1.id}")
     |> assign(:page_title, gettext("My wallet"))
     |> assign(:review_target, nil)
     |> assign(:review_form, nil)
     |> assign(:review_idempotency_key, nil)
     |> assign(:pending_redemption_allocation_id, nil)
     |> assign(:redemption_grant, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, subscriptions} <-
           Subscriptions.list_for_account(socket.assigns.current_account_scope, %{
             "limit" => "100"
           }),
         polos <- subscription_polos(subscriptions.subscriptions),
         {:ok, polo} <- select_polo(polos, params["polo"]),
         {:ok, wallet} <-
           Subscriptions.list_wallet(socket.assigns.current_account_scope, polo.slug),
         {:ok, history} <-
           Redemptions.list_for_member(tenant_scope(socket, polo), redemption_params(params)) do
      {:noreply,
       socket
       |> assign(:polos, polos)
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :wallet))
       |> assign(:voucher_index, Map.new(wallet.vouchers, &{&1.allocation_id, &1}))
       |> assign(:redemption_index, Map.new(history.redemptions, &{&1.id, &1}))
       |> assign(:next_page_path, next_page_path(polo, params, history.page))
       |> assign(:review_target, nil)
       |> assign(:review_form, nil)
       |> assign(:review_idempotency_key, nil)
       |> assign(:pending_redemption_allocation_id, nil)
       |> assign(:redemption_grant, nil)
       |> stream(:vouchers, wallet.vouchers, reset: true)
       |> stream(:redemptions, history.redemptions, reset: true)}
    else
      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The redemption page was invalid and has been reset."))
         |> redirect(to: ~p"/app/wallet")}

      {:error, :polo_not_found} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Join a Clubeira polo to unlock your wallet."))
         |> redirect(to: ~p"/app/catalog")}

      {:error, reason} ->
        Logger.error("could not load member wallet", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("Your wallet is temporarily unavailable."))
         |> redirect(to: ~p"/app")}
    end
  end

  @impl true
  def handle_event("change_wallet_polo", %{"wallet" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    selected = Enum.find(socket.assigns.polos, &(&1.slug == slug)) || socket.assigns.current_polo
    {:noreply, push_patch(socket, to: ~p"/app/wallet?#{[polo: selected.slug]}")}
  end

  def handle_event("change_wallet_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("review_redemption", %{"redemption-id" => redemption_id}, socket)
      when is_binary(redemption_id) do
    case Map.get(socket.assigns.redemption_index, redemption_id) do
      %{review: nil} = redemption ->
        changeset = Reviews.change_verified_submission(%{})

        {:noreply,
         socket
         |> assign(:review_target, redemption)
         |> assign(:review_form, to_form(changeset))
         |> assign(:review_idempotency_key, "review-#{Ecto.UUID.generate(version: 7)}")}

      _unavailable ->
        {:noreply,
         put_flash(socket, :error, gettext("This redemption is not available for review."))}
    end
  end

  def handle_event("review_redemption", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The review request was invalid."))}
  end

  def handle_event("validate_review", %{"submission" => params}, socket) when is_map(params) do
    changeset =
      params
      |> review_attributes(socket)
      |> Reviews.change_verified_submission()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :review_form, to_form(changeset))}
  end

  def handle_event("validate_review", _params, socket), do: {:noreply, socket}

  def handle_event("submit_review", %{"submission" => params}, socket) when is_map(params) do
    with %{review: nil} <- socket.assigns.review_target,
         {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         scope <- tenant_scope_for(account_scope, socket.assigns.current_polo),
         {:ok, _result} <-
           Reviews.submit_verified(scope, review_attributes(params, socket)) do
      {:noreply, refresh_after_review(socket, account_scope)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Choose a redemption before reviewing."))}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :review_form, to_form(changeset))}

      {:error, reason} ->
        Logger.warning("could not submit member review", reason: inspect(reason))

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The review could not be submitted. Please try again.")
         )}
    end
  end

  def handle_event("submit_review", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The review request was invalid."))}
  end

  def handle_event("cancel_review", _params, socket) do
    {:noreply,
     socket
     |> assign(:review_target, nil)
     |> assign(:review_form, nil)
     |> assign(:review_idempotency_key, nil)}
  end

  def handle_event("prepare_redemption", %{"allocation-id" => allocation_id}, socket)
      when is_binary(allocation_id) do
    case Map.get(socket.assigns.voucher_index, allocation_id) do
      %{available_units: units, places: [_place | _rest]} when units > 0 ->
        {:noreply,
         socket
         |> assign(:pending_redemption_allocation_id, allocation_id)
         |> assign(:redemption_grant, nil)
         |> push_event("request_installation_token", %{})}

      _unavailable ->
        {:noreply,
         put_flash(socket, :error, gettext("This voucher is not available for redemption."))}
    end
  end

  def handle_event("prepare_redemption", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The redemption request was invalid."))}
  end

  def handle_event(
        "issue_redemption_grant",
        %{"installation_token" => installation_token},
        socket
      )
      when is_binary(installation_token) do
    with allocation_id when is_binary(allocation_id) <-
           socket.assigns.pending_redemption_allocation_id,
         {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, wallet} <-
           Subscriptions.list_wallet(account_scope, socket.assigns.current_polo.slug),
         %{available_units: units, places: [_place | _rest]} = voucher when units > 0 <-
           Enum.find(wallet.vouchers, &(&1.allocation_id == allocation_id)),
         {:ok, _enrollment} <-
           Devices.enroll_redemption_device(account_scope, socket.assigns.current_polo.slug, %{
             "access_contract_id" => voucher.contract.id,
             "installation_token" => installation_token,
             "platform" => "web"
           }),
         {:ok, grant} <-
           Redemptions.issue_grant(account_scope, socket.assigns.current_polo.slug, %{
             "entitlement_allocation_id" => voucher.allocation_id,
             "installation_token" => installation_token
           }) do
      {:noreply,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:pending_redemption_allocation_id, nil)
       |> assign(:redemption_grant, %{grant: grant, voucher: voucher})}
    else
      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}

      nil ->
        redemption_unavailable(socket)

      {:error, reason} ->
        Logger.warning("could not issue browser redemption grant", reason: grant_error(reason))
        redemption_unavailable(socket)
    end
  end

  def handle_event("issue_redemption_grant", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The browser installation was invalid."))}
  end

  defp refresh_after_review(socket, account_scope) do
    case Redemptions.list_for_member(
           tenant_scope_for(account_scope, socket.assigns.current_polo),
           %{
             "limit" => @page_limit
           }
         ) do
      {:ok, history} ->
        socket
        |> assign(:current_account_scope, account_scope)
        |> assign(:redemption_index, Map.new(history.redemptions, &{&1.id, &1}))
        |> assign(:next_page_path, next_page_path(socket.assigns.current_polo, %{}, history.page))
        |> assign(:review_target, nil)
        |> assign(:review_form, nil)
        |> assign(:review_idempotency_key, nil)
        |> stream(:redemptions, history.redemptions, reset: true)
        |> put_flash(:info, gettext("Review submitted for moderation."))

      {:error, reason} ->
        Logger.error("could not refresh redemption history after review", reason: inspect(reason))

        socket
        |> assign(:review_target, nil)
        |> assign(:review_form, nil)
        |> assign(:review_idempotency_key, nil)
        |> put_flash(:info, gettext("Review submitted for moderation."))
    end
  end

  defp redemption_unavailable(socket) do
    {:noreply,
     socket
     |> assign(:pending_redemption_allocation_id, nil)
     |> assign(:redemption_grant, nil)
     |> put_flash(
       :error,
       gettext("A redemption code could not be issued. Refresh your wallet and try again.")
     )}
  end

  defp grant_error(%Ecto.Changeset{}), do: :invalid_request
  defp grant_error(reason) when is_atom(reason), do: reason
  defp grant_error(_reason), do: :unknown

  defp review_attributes(params, socket) do
    target = socket.assigns.review_target

    params
    |> Map.take(~w(rating title body))
    |> Map.put("place_id", target && target.place.id)
    |> Map.put("source_redemption_id", target && target.id)
    |> Map.put("idempotency_key", socket.assigns.review_idempotency_key)
  end

  defp subscription_polos(subscriptions) do
    subscriptions
    |> Enum.map(& &1.polo)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  defp select_polo([], _slug), do: {:error, :polo_not_found}

  defp select_polo(polos, slug),
    do: {:ok, Enum.find(polos, &(&1.slug == slug)) || List.first(polos)}

  defp redemption_params(params) do
    params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)
  end

  defp tenant_scope(socket, polo),
    do: tenant_scope_for(socket.assigns.current_account_scope, polo)

  defp tenant_scope_for(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query = [polo: polo.slug, after: page.next_cursor] |> maybe_put(:limit, params["limit"])
    ~p"/app/wallet?#{query}"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: query ++ [{key, value}]

  defp benefit_value(%{benefit_kind: "discount_percentage", percentage_value: value}, locale)
       when not is_nil(value),
       do: "#{decimal(value, locale)}%"

  defp benefit_value(%{amount_value: value, currency: currency}, locale)
       when not is_nil(value) and is_binary(currency),
       do: "#{currency} #{decimal(value, locale)}"

  defp benefit_value(_offer, _locale), do: gettext("Exclusive benefit")

  defp decimal(value, locale) do
    rendered = value |> Decimal.round(2) |> Decimal.to_string(:normal)
    if locale == "pt_BR", do: String.replace(rendered, ".", ","), else: rendered
  end

  defp timestamp(value, "pt_BR"), do: Calendar.strftime(value, "%d/%m/%Y · %H:%M")
  defp timestamp(value, _locale), do: Calendar.strftime(value, "%Y-%m-%d · %H:%M")
end
