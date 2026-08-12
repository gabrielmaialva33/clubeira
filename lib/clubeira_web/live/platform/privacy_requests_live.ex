defmodule ClubeiraWeb.Platform.PrivacyRequestsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PlatformAuth
  alias ClubeiraWeb.PlatformComponents

  @page_limit "20"

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> stream_configure(:requests, dom_id: &"privacy-request-#{&1.id}")
      |> assign(:page_title, gettext("Privacy requests"))

    case refresh_privacy_access(socket) do
      {:ok, socket, scope} -> load_first_page(socket, scope, params)
      {:error, reason} -> {:ok, redirect_access_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    with cursor when is_binary(cursor) <- socket.assigns.page.next_cursor,
         {:ok, socket, scope} <- refresh_privacy_access(socket),
         {:ok, result} <-
           Privacy.list_platform_requests(scope, %{
             "limit" => @page_limit,
             "after" => cursor
           }) do
      {:noreply,
       socket
       |> assign(:page, result.page)
       |> stream(:requests, result.requests)}
    else
      nil ->
        {:noreply, socket}

      {:error, reason} when reason in [:session_expired, :privacy_access_required] ->
        {:noreply, redirect_access_error(socket, reason)}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not load another privacy request page", reason: inspect(reason))

        {:noreply,
         put_flash(socket, :error, gettext("More privacy requests could not be loaded."))}
    end
  end

  defp load_first_page(socket, scope, params) do
    query_params =
      params
      |> Map.take(~w(after))
      |> Map.put("limit", @page_limit)

    case Privacy.list_platform_requests(scope, query_params) do
      {:ok, result} ->
        {:ok,
         socket
         |> assign(:page, result.page)
         |> stream(:requests, result.requests, reset: true)}

      {:error, :platform_privacy_officer_required} ->
        {:ok, redirect_access_error(socket, :privacy_access_required)}

      {:error, :invalid_pagination} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The request page was invalid and has been reset."))
         |> redirect(to: ~p"/platform/privacy/requests")}

      {:error, reason} ->
        Logger.error("could not load the privacy request queue", reason: inspect(reason))

        {:ok,
         socket
         |> put_flash(:error, gettext("The privacy request queue is temporarily unavailable."))
         |> redirect(to: ~p"/platform")}
    end
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

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")

  defp timestamp(%DateTime{} = datetime, _locale),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
