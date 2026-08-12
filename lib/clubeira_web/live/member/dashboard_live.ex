defmodule ClubeiraWeb.Member.DashboardLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Subscriptions
  alias ClubeiraWeb.MemberComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:subscriptions, dom_id: &"member-subscription-#{&1.id}")
      |> assign(:page_title, gettext("My Clubeira"))

    case Subscriptions.list_for_account(socket.assigns.current_account_scope, %{"limit" => "5"}) do
      {:ok, result} ->
        {:ok,
         socket
         |> assign(:subscription_count, length(result.subscriptions))
         |> assign(:has_more_subscriptions?, result.page.has_more)
         |> stream(:subscriptions, result.subscriptions)}

      {:error, reason} ->
        Logger.error("could not load member dashboard", reason: inspect(reason))

        {:ok,
         socket
         |> assign(:subscription_count, 0)
         |> assign(:has_more_subscriptions?, false)
         |> stream(:subscriptions, [])
         |> put_flash(:error, gettext("Your Clubeira overview is temporarily unavailable."))}
    end
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("past_due"), do: gettext("Past due")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label(status), do: String.replace(status, "_", " ")
end
