defmodule Clubeira.Subscriptions do
  @moduledoc """
  Subscription reads and commercial lifecycle boundaries.

  Member cross-polo discovery uses an actor-owned routing projection. Every
  contract, cycle, and allocation is then re-read inside that polo's RLS
  boundary. Administrative contract inventory remains tenant-scoped and
  requires the polo's billing capability.
  """

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Subscriptions.AccountSubscriptionReader
  alias Clubeira.Subscriptions.BackofficeSubscriptionReader
  alias Clubeira.Subscriptions.ContractLifecycle
  alias Clubeira.Subscriptions.ProductOfferingLifecycle
  alias Clubeira.Subscriptions.ProductOfferingPublisher
  alias Clubeira.Subscriptions.ProductOfferingReader
  alias Clubeira.Subscriptions.WalletReader
  alias Clubeira.Tenancy.Scope, as: TenantScope

  @type list_error :: :polo_not_found | term()
  @type page :: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}

  @doc """
  Publishes an initial direct subscription offering backed by published benefits.
  """
  @spec publish_product_offering(TenantScope.t(), map()) ::
          {:ok, ProductOfferingPublisher.result()} | {:error, term()}
  defdelegate publish_product_offering(scope, attributes),
    to: ProductOfferingPublisher,
    as: :publish

  @doc """
  Lists commercial offering identities and their latest immutable configuration.
  """
  @spec list_product_offerings(TenantScope.t(), map()) ::
          {:ok, %{product_offerings: [map()], page: page()}} | {:error, term()}
  defdelegate list_product_offerings(scope, params), to: ProductOfferingReader, as: :list

  @doc """
  Applies an authorized lifecycle action to a commercial offering.
  """
  @spec transition_product_offering(TenantScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, ProductOfferingLifecycle.result()} | {:error, term()}
  defdelegate transition_product_offering(scope, offering_id, attributes),
    to: ProductOfferingLifecycle,
    as: :transition

  @doc """
  Suspends or reactivates one access contract with temporal evidence.
  """
  @spec transition_contract(TenantScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate transition_contract(scope, contract_id, attributes),
    to: ContractLifecycle,
    as: :transition

  @doc """
  Lists the polo's access contracts for an authorized billing operator.
  """
  @spec list_backoffice_subscriptions(TenantScope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}} | {:error, term()}
  defdelegate list_backoffice_subscriptions(scope, params),
    to: BackofficeSubscriptionReader,
    as: :list

  @spec list_for_account(AccountScope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_for_account(%AccountScope{} = account_scope),
    do: AccountSubscriptionReader.list(account_scope)

  @spec list_for_account(AccountScope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}}
          | {:error, :invalid_pagination | term()}
  def list_for_account(%AccountScope{} = account_scope, params) when is_map(params),
    do: AccountSubscriptionReader.list(account_scope, params)

  @spec list_wallet(AccountScope.t(), String.t()) :: {:ok, map()} | {:error, list_error()}
  def list_wallet(%AccountScope{} = account_scope, polo_slug) when is_binary(polo_slug),
    do: WalletReader.get(account_scope, polo_slug)

  def list_wallet(%AccountScope{}, _polo_slug), do: {:error, :polo_not_found}
end
