defmodule ClubeiraWeb.Member.SubscriptionsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Subscriptions
  alias ClubeiraWeb.MemberComponents

  @query_fields ~w(after limit)
  @page_limit "20"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:subscriptions, dom_id: &"member-subscription-#{&1.id}")
     |> assign(:page_title, gettext("My subscriptions"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    case Subscriptions.list_for_account(socket.assigns.current_account_scope, query) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:limit_param, params["limit"])
         |> assign(:next_page_path, next_page_path(params, result.page))
         |> stream(:subscriptions, result.subscriptions, reset: true)}

      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The subscription page was invalid and has been reset."))
         |> redirect(to: ~p"/app/subscriptions")}

      {:error, reason} ->
        Logger.error("could not load member subscriptions", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("Your subscriptions are temporarily unavailable."))
         |> redirect(to: ~p"/app")}
    end
  end

  defp next_page_path(_params, %{has_more: false}), do: nil

  defp next_page_path(params, page) do
    query =
      [after: page.next_cursor]
      |> maybe_put(:limit, params["limit"])

    ~p"/app/subscriptions?#{query}"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: query ++ [{key, value}]

  defp status_label("active"), do: gettext("Active")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("past_due"), do: gettext("Past due")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label(status), do: String.replace(status, "_", " ")

  defp date(nil, _locale), do: gettext("No end date")
  defp date(%DateTime{} = value, "pt_BR"), do: Calendar.strftime(value, "%d/%m/%Y")
  defp date(%DateTime{} = value, _locale), do: Calendar.strftime(value, "%Y-%m-%d")
end
