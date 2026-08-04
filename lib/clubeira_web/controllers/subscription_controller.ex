defmodule ClubeiraWeb.SubscriptionController do
  use ClubeiraWeb, :controller

  alias Clubeira.Subscriptions

  def index(conn, _params) do
    {:ok, subscriptions} =
      Subscriptions.list_for_account(conn.assigns.current_account_scope)

    render(conn, :index, subscriptions: subscriptions)
  end
end
