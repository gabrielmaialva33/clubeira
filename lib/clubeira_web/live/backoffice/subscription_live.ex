defmodule ClubeiraWeb.Backoffice.SubscriptionLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @lifecycle_command_fields ~w(action idempotency_key reason)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Subscription details"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.backoffice_access.polos, params["polo"]) do
      {:ok, polo} -> load_subscription(socket, polo, params["contract_id"])
      {:invalid, fallback} -> redirect_invalid_polo(socket, fallback)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_navigate(socket, to: subscriptions_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  def handle_event("transition_contract", %{"lifecycle" => params}, socket)
      when is_map(params) do
    case refresh_account(socket) do
      {:ok, socket} -> process_transition_request(socket, params)
      :error -> redirect_expired_session(socket)
    end
  end

  def handle_event("transition_contract", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The lifecycle request was invalid and was not processed.")
     )}
  end

  defp load_subscription(socket, polo, contract_id) do
    if :manage_billing in polo.capabilities do
      scope = tenant_scope(socket.assigns.current_account_scope, polo)

      case Subscriptions.get_backoffice_subscription(scope, contract_id) do
        {:ok, subscription} ->
          {:noreply,
           socket
           |> assign(:current_polo, polo)
           |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
           |> assign_subscription(subscription)}

        {:error, :access_contract_not_found} ->
          redirect_missing(socket, polo)

        {:error, :billing_admin_required} ->
          redirect_unauthorized(socket, polo)

        {:error, reason} ->
          Logger.error("could not load backoffice subscription detail",
            polo_id: polo.id,
            access_contract_id: contract_id,
            reason: inspect(reason)
          )

          {:noreply,
           socket
           |> put_flash(:error, gettext("The subscription details are temporarily unavailable."))
           |> redirect(to: subscriptions_path(polo.slug))}
      end
    else
      redirect_unauthorized(socket, polo)
    end
  end

  defp select_polo(polos, nil), do: {:ok, List.first(polos)}

  defp select_polo(polos, slug) do
    case Enum.find(polos, &(&1.slug == slug)) do
      nil -> {:invalid, List.first(polos)}
      polo -> {:ok, polo}
    end
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp refresh_account(socket) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> {:ok, assign(socket, :current_account_scope, account_scope)}
      :error -> :error
    end
  end

  defp process_transition_request(%{assigns: %{lifecycle_form: nil}} = socket, _params) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("This lifecycle action is no longer available for the current state.")
     )}
  end

  defp process_transition_request(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    attributes = Map.take(params, @lifecycle_command_fields)

    scope
    |> Subscriptions.transition_contract(socket.assigns.subscription.id, attributes)
    |> handle_transition_result(socket, params)
  end

  defp handle_transition_result({:ok, _result}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext("The subscription lifecycle was updated successfully.")
    )
  end

  defp handle_transition_result({:error, :invalid_access_contract_transition}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext("This lifecycle action is no longer available for the current state."),
      :error
    )
  end

  defp handle_transition_result({:error, :request_in_progress}, socket, params) do
    {:noreply,
     socket
     |> assign(:lifecycle_form, form_from_params(params))
     |> put_flash(
       :error,
       gettext("This request is still being processed. Retry with the same values.")
     )}
  end

  defp handle_transition_result({:error, :idempotency_conflict}, socket, _params) do
    refresh_after_transition(
      socket,
      gettext(
        "This request changed after it started. Review the current state and submit again."
      ),
      :error
    )
  end

  defp handle_transition_result({:error, %Ecto.Changeset{} = changeset}, socket, _params) do
    {:noreply,
     socket
     |> assign(:lifecycle_form, to_form(changeset, as: :lifecycle))
     |> put_flash(:error, gettext("Review the lifecycle action before submitting."))}
  end

  defp handle_transition_result({:error, :access_contract_not_found}, socket, _params) do
    redirect_missing(socket, socket.assigns.current_polo)
  end

  defp handle_transition_result({:error, :billing_admin_required}, socket, _params) do
    redirect_unauthorized(socket, socket.assigns.current_polo)
  end

  defp handle_transition_result({:error, reason}, socket, _params) do
    Logger.error("could not transition backoffice subscription",
      polo_id: socket.assigns.current_polo.id,
      access_contract_id: socket.assigns.subscription.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The lifecycle action could not be completed."))}
  end

  defp refresh_after_transition(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    contract_id = socket.assigns.subscription.id

    case Subscriptions.get_backoffice_subscription(scope, contract_id) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> assign_subscription(subscription)
         |> put_flash(flash_kind, message)}

      {:error, :access_contract_not_found} ->
        redirect_missing(socket, socket.assigns.current_polo)

      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload backoffice subscription after lifecycle transition",
          polo_id: socket.assigns.current_polo.id,
          access_contract_id: contract_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated subscription could not be reloaded."))
         |> redirect(to: subscriptions_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_subscription(socket, subscription) do
    socket
    |> assign(:subscription, subscription)
    |> assign(:lifecycle_actions, lifecycle_actions(subscription.status))
    |> assign(:lifecycle_form, lifecycle_form(subscription))
  end

  defp lifecycle_form(subscription) do
    case lifecycle_actions(subscription.status) do
      [{_label, default_action}] ->
        to_form(
          Subscriptions.change_contract_lifecycle(%{
            action: default_action,
            reason: "",
            idempotency_key: lifecycle_idempotency_key()
          }),
          as: :lifecycle
        )

      [] ->
        nil
    end
  end

  defp form_from_params(params) do
    params
    |> Subscriptions.change_contract_lifecycle()
    |> to_form(as: :lifecycle)
  end

  defp lifecycle_actions(status) when status in ["active", "past_due"],
    do: [{gettext("Suspend"), "suspend"}]

  defp lifecycle_actions("suspended"), do: [{gettext("Reactivate"), "reactivate"}]
  defp lifecycle_actions(_status), do: []

  defp lifecycle_idempotency_key do
    "subscription-lifecycle-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp subscriptions_path(polo_slug), do: ~p"/admin/subscriptions?#{[polo: polo_slug]}"

  defp redirect_invalid_polo(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: subscriptions_path(polo.slug))}
  end

  defp redirect_missing(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The subscription was not found in this polo."))
     |> redirect(to: subscriptions_path(polo.slug))}
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage subscriptions."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
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

  defp order_status_label("pending"), do: gettext("Pending")
  defp order_status_label("awaiting_payment"), do: gettext("Awaiting payment")
  defp order_status_label("paid"), do: gettext("Paid")
  defp order_status_label("cancelled"), do: gettext("Cancelled")
  defp order_status_label("expired"), do: gettext("Expired")
  defp order_status_label("refunded"), do: gettext("Refunded")
  defp order_status_label("charged_back"), do: gettext("Charged back")
end
