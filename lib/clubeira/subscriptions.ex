defmodule Clubeira.Subscriptions do
  @moduledoc """
  Subscription reads and commercial lifecycle boundaries.

  Member cross-polo discovery uses an actor-owned routing projection. Every
  contract, cycle, and allocation is then re-read inside that polo's RLS
  boundary. Administrative contract inventory remains tenant-scoped and
  requires the polo's billing capability.
  """

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Polos
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BackofficeSubscriptionReader
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementScopePlace
  alias Clubeira.Subscriptions.ProductOfferingLifecycle
  alias Clubeira.Subscriptions.ProductOfferingPublisher
  alias Clubeira.Subscriptions.ProductOfferingReader
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Subscriptions.UserContractPoloRoute
  alias Clubeira.Tenancy.ActorScope
  alias Clubeira.Tenancy.Scope, as: TenantScope

  @default_route_page_limit 20
  @maximum_route_page_limit 100

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
  Lists the polo's access contracts for an authorized billing operator.
  """
  @spec list_backoffice_subscriptions(TenantScope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}} | {:error, term()}
  defdelegate list_backoffice_subscriptions(scope, params),
    to: BackofficeSubscriptionReader,
    as: :list

  @spec list_for_account(AccountScope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_for_account(%AccountScope{} = account_scope) do
    with {:ok, routes} <- discover_actor_routes(account_scope) do
      list_routes(routes, account_scope)
    end
  end

  @spec list_for_account(AccountScope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}}
          | {:error, :invalid_pagination | term()}
  def list_for_account(%AccountScope{} = account_scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_route_pagination(params),
         {:ok, %{routes: routes, page: page}} <-
           discover_actor_route_page(account_scope, pagination),
         {:ok, subscriptions} <- list_routes(routes, account_scope) do
      {:ok, %{subscriptions: subscriptions, page: page}}
    end
  end

  @spec list_wallet(AccountScope.t(), String.t()) :: {:ok, map()} | {:error, list_error()}
  def list_wallet(%AccountScope{} = account_scope, polo_slug) when is_binary(polo_slug) do
    with {:ok, route} <- Polos.resolve_route(polo_slug) do
      tenant_scope = tenant_scope(account_scope, route.polo_id)

      Repo.transact_in_polo(tenant_scope, fn repo ->
        list_wallet_in_route(repo, account_scope.user.id, route)
      end)
    end
  end

  def list_wallet(%AccountScope{}, _polo_slug), do: {:error, :polo_not_found}

  defp discover_actor_routes(account_scope) do
    actor_scope = ActorScope.new!(account_scope.user.id, account_scope.request_id)

    Repo.transact_as_actor(actor_scope, fn repo ->
      {:ok, list_actor_routes(repo, account_scope.user.id)}
    end)
  end

  defp discover_actor_route_page(account_scope, pagination) do
    actor_scope = ActorScope.new!(account_scope.user.id, account_scope.request_id)

    Repo.transact_as_actor(actor_scope, fn repo ->
      {:ok, list_actor_route_page(repo, account_scope.user.id, pagination)}
    end)
  end

  defp list_actor_routes(repo, user_id) do
    user_id
    |> actor_routes_query()
    |> repo.all()
  end

  defp list_actor_route_page(repo, user_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      user_id
      |> actor_routes_query()
      |> after_actor_route(pagination.after)
      |> limit(^query_limit)
      |> repo.all()

    {routes, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      routes: routes,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_route_cursor(routes, has_more)
      }
    }
  end

  defp actor_routes_query(user_id) do
    UserContractPoloRoute
    |> join(:inner, [route], polo_route in PoloRoute, on: polo_route.polo_id == route.polo_id)
    |> where([route], route.user_id == ^user_id)
    |> order_by([route], asc: route.first_contract_at, asc: route.polo_id)
    |> select([route, polo_route], %{
      polo_id: route.polo_id,
      slug: polo_route.slug,
      first_contract_at: route.first_contract_at
    })
  end

  defp after_actor_route(query, nil), do: query

  defp after_actor_route(query, %{first_contract_at: first_contract_at, polo_id: polo_id}) do
    where(
      query,
      [route],
      route.first_contract_at > ^first_contract_at or
        (route.first_contract_at == ^first_contract_at and route.polo_id > ^polo_id)
    )
  end

  defp list_routes(routes, account_scope) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route, {:ok, accumulated} ->
      prepend_route_contracts(route, account_scope, accumulated)
    end)
    |> flatten_route_contracts()
  end

  defp prepend_route_contracts(route, account_scope, accumulated) do
    case contracts_in_route(route, account_scope) do
      {:ok, contracts} -> {:cont, {:ok, [contracts | accumulated]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp flatten_route_contracts({:ok, contract_groups}) do
    {:ok, contract_groups |> Enum.reverse() |> List.flatten()}
  end

  defp flatten_route_contracts({:error, reason}), do: {:error, reason}

  defp contracts_in_route(route, account_scope) do
    scope = tenant_scope(account_scope, route.polo_id)

    Repo.transact_in_polo(scope, fn repo ->
      case fetch_polo(repo, route) do
        {:ok, polo} -> {:ok, list_contracts(repo, account_scope.user.id, polo)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp list_wallet_in_route(repo, user_id, route) do
    case fetch_polo(repo, route) do
      {:ok, polo} -> {:ok, build_wallet(repo, user_id, polo)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_wallet(repo, user_id, polo) do
    allocations = list_wallet_allocations(repo, user_id)
    places_by_allocation = list_wallet_places(repo, user_id)

    vouchers =
      Enum.map(allocations, fn allocation ->
        Map.put(allocation, :places, Map.get(places_by_allocation, allocation.allocation_id, []))
      end)

    %{polo: polo, vouchers: vouchers}
  end

  defp list_contracts(repo, user_id, polo) do
    AccessContract
    |> join(:inner, [contract], offering in ProductOfferingVersion,
      on:
        offering.id == contract.product_offering_version_id and
          offering.polo_id == contract.polo_id
    )
    |> join(:left, [contract], cycle in BenefitCycle,
      on:
        cycle.access_contract_id == contract.id and
          cycle.polo_id == contract.polo_id and
          cycle.status == "active" and
          fragment("? @> statement_timestamp()", cycle.benefits_during)
    )
    |> where([contract], contract.purchaser_user_id == ^user_id)
    |> order_by([contract], desc: contract.inserted_at, desc: contract.id)
    |> select([contract, offering, cycle], %{
      id: contract.id,
      status: contract.status,
      starts_at: contract.starts_at,
      activated_at: contract.activated_at,
      ends_at: contract.ends_at,
      cancelled_at: contract.cancelled_at,
      offering: %{
        version_id: offering.id,
        version: offering.version,
        name: offering.name,
        description: offering.description,
        cycle_policy: offering.cycle_policy,
        cycle_interval_unit: offering.cycle_interval_unit,
        cycle_interval_count: offering.cycle_interval_count,
        renewal_policy: offering.renewal_policy
      },
      current_cycle: %{
        id: cycle.id,
        sequence: cycle.sequence,
        status: cycle.status,
        starts_at: fragment("lower(?)", cycle.benefits_during),
        ends_at: fragment("upper(?)", cycle.benefits_during)
      }
    })
    |> repo.all()
    |> Enum.map(fn contract ->
      contract
      |> Map.put(:polo, polo)
      |> empty_cycle_to_nil()
    end)
  end

  defp empty_cycle_to_nil(%{current_cycle: %{id: nil}} = contract) do
    %{contract | current_cycle: nil}
  end

  defp empty_cycle_to_nil(contract), do: contract

  defp list_wallet_allocations(repo, user_id) do
    user_id
    |> wallet_query()
    |> select(
      [
        allocation: allocation,
        subject: subject,
        contract: contract,
        cycle: cycle,
        item: item,
        offer_version: offer_version,
        offer: offer
      ],
      %{
        allocation_id: allocation.id,
        allocation_kind: allocation.allocation_kind,
        issued_units: allocation.issued_units,
        available_units: allocation.available_units,
        contract: %{id: contract.id, status: contract.status},
        cycle: %{
          id: cycle.id,
          sequence: cycle.sequence,
          status: cycle.status,
          starts_at: fragment("lower(?)", cycle.benefits_during),
          ends_at: fragment("upper(?)", cycle.benefits_during)
        },
        subject: %{
          kind: subject.subject_kind,
          contract_beneficiary_id: subject.contract_beneficiary_id
        },
        allowance: %{
          per_cycle: item.allowance_per_cycle,
          consumption_unit: item.consumption_unit,
          subject_policy: item.subject_policy
        },
        offer: %{
          id: offer.id,
          version_id: offer_version.id,
          version: offer_version.version,
          code: offer.code,
          name: offer.name,
          title: offer_version.title,
          description: offer_version.description,
          terms: offer_version.terms,
          redemption_instructions: offer_version.redemption_instructions,
          benefit_kind: offer.benefit_kind,
          percentage_value: offer_version.percentage_value,
          amount_value: offer_version.amount_value,
          currency: offer_version.currency
        }
      }
    )
    |> order_by([allocation: allocation], asc: allocation.id)
    |> repo.all()
  end

  defp list_wallet_places(repo, user_id) do
    user_id
    |> wallet_query()
    |> join(:inner, [offer_version: offer_version], offer_place in BenefitOfferVersionPlace,
      as: :offer_place,
      on:
        offer_place.polo_id == offer_version.polo_id and
          offer_place.benefit_offer_version_id == offer_version.id
    )
    |> join(:inner, [offer_place: offer_place], polo_place in PoloPlace,
      as: :polo_place,
      on:
        polo_place.polo_id == offer_place.polo_id and
          polo_place.id == offer_place.polo_place_id
    )
    |> join(
      :left,
      [allocation: allocation, polo_place: polo_place],
      scope_place in EntitlementScopePlace,
      as: :scope_place,
      on:
        scope_place.polo_id == allocation.polo_id and
          scope_place.entitlement_scope_id == allocation.entitlement_scope_id and
          scope_place.polo_place_id == polo_place.id
    )
    |> join(:inner, [polo_place: polo_place], place in Place,
      as: :place,
      on: place.id == polo_place.place_id
    )
    |> where(
      [allocation: allocation, polo_place: polo_place, scope_place: scope_place],
      (allocation.allocation_kind == "per_place" and
         allocation.polo_place_id == polo_place.id) or
        (allocation.allocation_kind == "shared_scope" and
           not is_nil(scope_place.entitlement_scope_id))
    )
    |> where([polo_place: polo_place], polo_place.status == "active")
    |> where(
      [polo_place: polo_place],
      fragment("? @> statement_timestamp()", polo_place.participation_during)
    )
    |> where([place: place], place.status == "active")
    |> order_by([allocation: allocation, place: place, polo_place: polo_place],
      asc: allocation.id,
      asc: place.name,
      asc: polo_place.id
    )
    |> select([allocation: allocation, polo_place: polo_place, place: place], %{
      allocation_id: allocation.id,
      polo_place_id: polo_place.id,
      place_id: place.id,
      slug: place.slug,
      name: place.name
    })
    |> repo.all()
    |> Enum.group_by(& &1.allocation_id, &Map.delete(&1, :allocation_id))
  end

  defp wallet_query(user_id) do
    EntitlementAllocation
    |> from(as: :allocation)
    |> join_wallet_relations()
    |> filter_wallet_owner(user_id)
    |> filter_current_wallet()
  end

  defp join_wallet_relations(query) do
    query
    |> join(:inner, [allocation: allocation], subject in CycleEntitlementSubject,
      as: :subject,
      on:
        subject.id == allocation.cycle_entitlement_subject_id and
          subject.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, subject: subject], contract in AccessContract,
      as: :contract,
      on:
        contract.id == subject.access_contract_id and
          contract.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, subject: subject], cycle in BenefitCycle,
      as: :cycle,
      on:
        cycle.id == subject.benefit_cycle_id and
          cycle.polo_id == allocation.polo_id and
          cycle.access_contract_id == subject.access_contract_id
    )
    |> join(:inner, [allocation: allocation, cycle: cycle], policy in PoloPolicyVersion,
      as: :policy,
      on:
        policy.id == cycle.polo_policy_version_id and
          policy.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation], item in BenefitPackageItem,
      as: :item,
      on:
        item.id == allocation.benefit_package_item_id and
          item.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, item: item], offer_version in BenefitOfferVersion,
      as: :offer_version,
      on:
        offer_version.id == item.benefit_offer_version_id and
          offer_version.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, offer_version: offer_version], offer in BenefitOffer,
      as: :offer,
      on:
        offer.id == offer_version.benefit_offer_id and
          offer.polo_id == allocation.polo_id
    )
  end

  defp filter_wallet_owner(query, user_id) do
    query
    |> where([subject: subject], subject.subject_kind == "contract")
    |> where([contract: contract], contract.purchaser_user_id == ^user_id)
  end

  defp filter_current_wallet(query) do
    query
    |> where(
      [contract: contract, cycle: cycle, policy: policy],
      contract.status == "active" or
        (contract.status == "past_due" and
           policy.delinquency_mode == "grace_period" and
           cycle.delinquency_grace_until >= fragment("statement_timestamp()"))
    )
    |> where(
      [contract: contract],
      is_nil(contract.starts_at) or contract.starts_at <= fragment("statement_timestamp()")
    )
    |> where(
      [contract: contract],
      is_nil(contract.ends_at) or contract.ends_at > fragment("statement_timestamp()")
    )
    |> where([cycle: cycle], cycle.status == "active")
    |> where(
      [cycle: cycle],
      fragment("? @> statement_timestamp()", cycle.benefits_during)
    )
    |> where(
      [allocation: allocation, cycle: cycle, item: item],
      item.benefit_package_version_id == cycle.benefit_package_version_id and
        allocation.entitlement_scope_id == item.entitlement_scope_id and
        allocation.allocation_kind == item.consumption_unit
    )
    |> where([offer: offer], offer.status == "active")
    |> where([offer_version: offer_version], offer_version.status == "published")
    |> where(
      [offer_version: offer_version],
      fragment("? @> statement_timestamp()", offer_version.effective_during)
    )
  end

  defp fetch_polo(repo, %{polo_id: polo_id, slug: slug}) do
    case repo.get(Polo, polo_id) do
      %Polo{} = polo ->
        {:ok,
         %{
           id: polo.id,
           slug: slug,
           name: polo.name,
           timezone: polo.timezone,
           status: polo.status
         }}

      nil ->
        {:error, :polo_not_found}
    end
  end

  defp tenant_scope(account_scope, polo_id) do
    TenantScope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp parse_route_pagination(params) do
    with {:ok, limit} <- parse_route_limit(Map.get(params, "limit")),
         {:ok, after_route} <- parse_route_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_route}}
    else
      :error -> {:error, :invalid_pagination}
    end
  end

  defp parse_route_limit(nil), do: {:ok, @default_route_page_limit}

  defp parse_route_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_route_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_route_limit(_limit), do: :error

  defp parse_route_cursor(nil), do: {:ok, nil}

  defp parse_route_cursor(cursor) when is_binary(cursor) do
    with {:ok, <<unix_microsecond::signed-64, polo_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, first_contract_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, polo_id} <- Ecto.UUID.load(polo_id_binary) do
      {:ok, %{first_contract_at: first_contract_at, polo_id: polo_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_route_cursor(_cursor), do: :error

  defp next_route_cursor(_routes, false), do: nil

  defp next_route_cursor(routes, true) do
    %{first_contract_at: first_contract_at, polo_id: polo_id} = List.last(routes)
    unix_microsecond = DateTime.to_unix(first_contract_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(polo_id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
