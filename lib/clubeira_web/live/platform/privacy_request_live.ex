defmodule ClubeiraWeb.Platform.PrivacyRequestLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PlatformAuth
  alias ClubeiraWeb.PlatformComponents

  @transition_fields ~w(action rejection_reason)

  @impl true
  def mount(%{"request_id" => request_id}, _session, socket) do
    socket =
      socket
      |> stream_configure(:events, dom_id: &"privacy-request-event-#{&1.stream_index}")
      |> assign(:page_title, gettext("Privacy request"))

    with {:ok, socket, scope} <- refresh_privacy_access(socket),
         {:ok, request} <- Privacy.get_platform_request(scope, request_id) do
      {:ok, assign_request(socket, request)}
    else
      {:error, reason} when reason in [:session_expired, :privacy_access_required] ->
        {:ok, redirect_access_error(socket, reason)}

      {:error, :platform_privacy_officer_required} ->
        {:ok, redirect_access_error(socket, :privacy_access_required)}

      {:error, :privacy_request_not_found} ->
        {:ok, redirect_missing_request(socket)}

      {:error, reason} ->
        Logger.error("could not load privacy request detail", reason: inspect(reason))

        {:ok,
         socket
         |> put_flash(:error, gettext("The privacy request is temporarily unavailable."))
         |> redirect(to: ~p"/platform/privacy/requests")}
    end
  end

  def mount(_params, _session, socket), do: {:ok, redirect_missing_request(socket)}

  @impl true
  def handle_event("transition", %{"transition" => params}, socket)
      when is_map(params) and not is_struct(params) do
    case refresh_privacy_access(socket) do
      {:ok, socket, scope} ->
        attributes =
          params
          |> Map.take(@transition_fields)
          |> Map.put("expected_status", socket.assigns.request.status)

        transition_request(socket, scope, attributes)

      {:error, reason} ->
        {:noreply, redirect_access_error(socket, reason)}
    end
  end

  def handle_event("transition", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The privacy request transition was invalid."))}
  end

  defp transition_request(socket, scope, attributes) do
    case Privacy.transition_request(scope, socket.assigns.request.id, attributes) do
      {:ok, %{request: request}} ->
        {:noreply,
         socket
         |> assign_request(request)
         |> put_flash(:info, gettext("The privacy request was updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:transition_form, to_form(changeset, as: :transition))
         |> put_flash(:error, gettext("Review the transition before submitting."))}

      {:error, reason}
      when reason in [:stale_privacy_request, :invalid_privacy_request_transition] ->
        reload_request(
          socket,
          scope,
          gettext("The request changed before this action completed. Review its current state."),
          :error
        )

      {:error, :privacy_request_not_found} ->
        {:noreply, redirect_missing_request(socket)}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not transition privacy request",
          request_id: socket.assigns.request.id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The privacy request could not be updated."))}
    end
  end

  defp reload_request(socket, scope, message, flash_kind) do
    case Privacy.get_platform_request(scope, socket.assigns.request.id) do
      {:ok, request} ->
        {:noreply,
         socket
         |> assign_request(request)
         |> put_flash(flash_kind, message)}

      {:error, :privacy_request_not_found} ->
        {:noreply, redirect_missing_request(socket)}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not reload privacy request detail",
          request_id: socket.assigns.request.id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The updated privacy request could not be loaded."))}
    end
  end

  defp assign_request(socket, request) do
    events =
      request.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :stream_index, index) end)

    socket
    |> assign(:request, request)
    |> assign(:available_actions, Privacy.available_actions(request.status))
    |> assign(:transition_form, transition_form(request.status))
    |> stream(:events, events, reset: true)
  end

  defp transition_form(status) do
    %{"action" => "", "expected_status" => status, "rejection_reason" => ""}
    |> Privacy.change_request_transition()
    |> to_form(as: :transition)
  end

  defp refresh_privacy_access(socket) do
    with {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, access} <- PlatformAuth.authorize(account_scope),
         true <- :manage_privacy in access.capabilities do
      scope = ActorScope.new!(account_scope.user.id, account_scope.request_id)

      {:ok,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:platform_access, access), scope}
    else
      :error -> {:error, :session_expired}
      _forbidden -> {:error, :privacy_access_required}
    end
  end

  defp redirect_missing_request(socket) do
    socket
    |> put_flash(:error, gettext("The privacy request was not found."))
    |> redirect(to: ~p"/platform/privacy/requests")
  end

  defp redirect_access_error(socket, :session_expired) do
    socket
    |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
    |> redirect(to: ~p"/platform/login")
  end

  defp redirect_access_error(socket, :privacy_access_required) do
    socket
    |> put_flash(:error, gettext("You do not have access to privacy operations."))
    |> redirect(to: ~p"/platform")
  end

  defp timestamp(nil, _locale), do: gettext("Not available")

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")

  defp timestamp(%DateTime{} = datetime, _locale),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp action_label("start_identity_verification"), do: gettext("Start identity verification")
  defp action_label("start_processing"), do: gettext("Start processing")
  defp action_label("complete"), do: gettext("Complete request")
  defp action_label("partially_complete"), do: gettext("Partially complete")
  defp action_label("reject"), do: gettext("Reject request")
  defp action_label("cancel"), do: gettext("Cancel request")
  defp action_label(action), do: humanized(action)

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
