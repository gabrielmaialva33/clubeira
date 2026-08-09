defmodule Clubeira.PlatformBilling do
  @moduledoc """
  Platform plan catalog and the SaaS billing lifecycle of each polo.
  """

  alias Clubeira.Platform.BillingReader
  alias Clubeira.Platform.PlanPublisher
  alias Clubeira.Platform.PlanReader
  alias Clubeira.Platform.SubscriptionStarter
  alias Clubeira.Tenancy.ActorScope
  alias Clubeira.Tenancy.Scope

  @spec publish_plan(ActorScope.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate publish_plan(scope, code, version, attributes),
    to: PlanPublisher,
    as: :publish

  @spec list_plans(ActorScope.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_plans(scope), to: PlanReader, as: :list

  @spec start_subscription(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate start_subscription(scope, attributes), to: SubscriptionStarter, as: :start

  @spec get_billing(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_billing(scope), to: BillingReader, as: :read
end
