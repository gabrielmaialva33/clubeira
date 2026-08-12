defmodule Clubeira.PlatformBilling do
  @moduledoc """
  Platform plan catalog and the SaaS billing lifecycle of each polo.
  """

  alias Clubeira.Platform.BillingReader
  alias Clubeira.Platform.ManagedPlanReader
  alias Clubeira.Platform.PlanPublisher
  alias Clubeira.Platform.PlanPublishRequest
  alias Clubeira.Platform.PlanReader
  alias Clubeira.Platform.SubscriptionOptionsReader
  alias Clubeira.Platform.SubscriptionStarter
  alias Clubeira.Platform.SubscriptionStartRequest
  alias Clubeira.Tenancy.ActorScope
  alias Clubeira.Tenancy.Scope

  @spec publish_plan(ActorScope.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate publish_plan(scope, code, version, attributes),
    to: PlanPublisher,
    as: :publish

  @doc false
  @spec change_plan_publish_request(term()) :: Ecto.Changeset.t()
  def change_plan_publish_request(attributes \\ %{}) do
    PlanPublishRequest.change(attributes)
  end

  @doc """
  Lists the currently purchasable plan versions for the global billing control plane.

  This boundary requires a current platform billing role. It is not the
  tenant-scoped subscription-options inventory used by a polo administrator.
  """
  @spec list_plans(ActorScope.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_plans(scope), to: PlanReader, as: :list

  @doc """
  Lists the global management inventory of platform plans and their immutable versions.
  """
  @spec list_managed_plans(ActorScope.t(), map()) ::
          {:ok, %{plans: [map()], page: map()}} | {:error, term()}
  defdelegate list_managed_plans(scope, params), to: ManagedPlanReader, as: :list

  @spec start_subscription(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate start_subscription(scope, attributes), to: SubscriptionStarter, as: :start

  @doc """
  Lists the currently purchasable SaaS prices for an authorized polo billing admin.

  Unlike `list_plans/1`, this tenant boundary is explicitly intended for
  choosing the `platform_price_id` accepted by `start_subscription/2`.
  """
  @spec list_subscription_options(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_subscription_options(scope), to: SubscriptionOptionsReader, as: :list

  @doc false
  @spec change_subscription_start_request(term()) :: Ecto.Changeset.t()
  def change_subscription_start_request(attributes \\ %{}) do
    SubscriptionStartRequest.change(attributes)
  end

  @spec get_billing(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_billing(scope), to: BillingReader, as: :read
end
