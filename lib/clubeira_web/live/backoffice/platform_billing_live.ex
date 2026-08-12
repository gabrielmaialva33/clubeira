defmodule ClubeiraWeb.Backoffice.PlatformBillingLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.PlatformBilling
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @start_fields ~w(idempotency_key platform_price_id)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Clubeira billing"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_billing in polo.capabilities do
      load_workspace(socket, polo)
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

    {:noreply, push_patch(socket, to: billing_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event("start_platform_subscription", %{"platform_subscription" => params}, socket)
      when is_map(params) do
    price_id = params["platform_price_id"]

    if option_available?(socket.assigns.subscription_options, price_id) do
      case Accounts.refresh_scope(socket.assigns.current_account_scope) do
        {:ok, account_scope} ->
          socket
          |> assign(:current_account_scope, account_scope)
          |> start_subscription(Map.take(params, @start_fields))

        :error ->
          redirect_expired_session(socket)
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("The selected SaaS price is no longer available."))}
    end
  end

  def handle_event("start_platform_subscription", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The SaaS subscription request was invalid."))}
  end

  defp load_workspace(socket, polo) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    with {:ok, billing} <- PlatformBilling.get_billing(scope),
         {:ok, options} <- PlatformBilling.list_subscription_options(scope) do
      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(:billing, billing)
       |> assign(:subscription_options, options)
       |> assign(:start_form, new_start_form(options))}
    else
      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, :polo_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The selected polo is not available."))
         |> redirect(to: ~p"/admin")}

      {:error, reason} ->
        Logger.error("could not load platform billing workspace",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The Clubeira billing workspace is temporarily unavailable.")
         )
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp start_subscription(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case PlatformBilling.start_subscription(scope, params) do
      {:ok, result} ->
        refresh_after_start(socket, result)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:start_form, to_form(changeset, as: :platform_subscription))
         |> put_flash(:error, gettext("Review the SaaS subscription before submitting."))}

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :platform_subscription_already_active,
             :request_in_progress
           ] ->
        reload_billing(
          socket,
          gettext("The SaaS subscription changed before this request completed."),
          :error
        )

      {:error, :platform_price_not_found} ->
        reload_workspace(
          socket,
          gettext("The selected SaaS price is no longer available."),
          :error
        )

      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason}
      when reason in [
             :payment_gateway_invalid_response,
             :payment_gateway_not_configured,
             :platform_subscription_unsupported
           ] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The SaaS payment gateway could not start this subscription.")
         )}

      {:error, reason} ->
        Logger.error("could not start platform subscription from backoffice",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The SaaS subscription could not be started."))}
    end
  end

  defp refresh_after_start(socket, result) do
    next_action = result.subscription.next_action

    if next_action["type"] == "redirect" and valid_redirect_url?(next_action["url"]) do
      {:noreply, redirect(socket, external: next_action["url"])}
    else
      reload_billing(socket, gettext("The SaaS subscription was started."))
    end
  end

  defp reload_workspace(socket, message, flash_kind) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    with {:ok, billing} <- PlatformBilling.get_billing(scope),
         {:ok, options} <- PlatformBilling.list_subscription_options(scope) do
      {:noreply,
       socket
       |> assign(:billing, billing)
       |> assign(:subscription_options, options)
       |> assign(:start_form, new_start_form(options))
       |> put_flash(flash_kind, message)}
    else
      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload platform billing workspace",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated Clubeira billing view could not be reloaded."))
         |> redirect(to: billing_path(socket.assigns.current_polo.slug))}
    end
  end

  defp reload_billing(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case PlatformBilling.get_billing(scope) do
      {:ok, billing} ->
        {:noreply,
         socket
         |> assign(:billing, billing)
         |> assign(:start_form, new_start_form(socket.assigns.subscription_options))
         |> put_flash(flash_kind, message)}

      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload platform billing view",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated Clubeira billing view could not be reloaded."))
         |> redirect(to: billing_path(socket.assigns.current_polo.slug))}
    end
  end

  defp new_start_form([]) do
    %{"idempotency_key" => "platform-subscription-#{uuid7()}"}
    |> PlatformBilling.change_subscription_start_request()
    |> to_form(as: :platform_subscription)
  end

  defp new_start_form([option | _rest]) do
    %{
      "platform_price_id" => option.price.id,
      "idempotency_key" => "platform-subscription-#{uuid7()}"
    }
    |> PlatformBilling.change_subscription_start_request()
    |> to_form(as: :platform_subscription)
  end

  defp option_available?(options, price_id) when is_binary(price_id),
    do: Enum.any?(options, &(&1.price.id == price_id))

  defp option_available?(_options, _price_id), do: false

  defp valid_redirect_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _invalid -> false
    end
  end

  defp valid_redirect_url?(_url), do: false

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp billing_path(polo_slug), do: ~p"/admin/platform-billing?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage Clubeira billing."))
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
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("past_due"), do: gettext("Past due")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label(status), do: status
end
