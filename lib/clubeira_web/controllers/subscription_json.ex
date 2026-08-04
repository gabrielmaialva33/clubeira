defmodule ClubeiraWeb.SubscriptionJSON do
  @moduledoc false

  def index(%{subscriptions: subscriptions}) do
    %{data: subscriptions, meta: %{count: length(subscriptions)}}
  end
end
