defmodule ClubeiraWeb.Member.SubscriptionJSON do
  @moduledoc false

  def index(%{subscriptions: subscriptions, page: page}) do
    %{data: subscriptions, meta: %{count: length(subscriptions), page: page}}
  end
end
