defmodule ClubeiraWeb.Platform.DashboardLive do
  use ClubeiraWeb, :live_view

  alias ClubeiraWeb.PlatformComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Platform overview"))}
  end
end
