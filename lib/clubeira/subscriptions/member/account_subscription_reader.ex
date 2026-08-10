defmodule Clubeira.Subscriptions.AccountSubscriptionReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.MemberPoloBoundary
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Subscriptions.UserContractPoloRoute
  alias Clubeira.Tenancy.ActorScope

  @default_page_limit 20
  @maximum_page_limit 100

  @type page :: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}

  @spec list(AccountScope.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%AccountScope{} = account_scope) do
    with {:ok, routes} <- discover_actor_routes(account_scope) do
      list_routes(routes, account_scope)
    end
  end

  @spec list(AccountScope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}}
          | {:error, :invalid_pagination | term()}
  def list(%AccountScope{} = account_scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, %{routes: routes, page: page}} <-
           discover_actor_route_page(account_scope, pagination),
         {:ok, subscriptions} <- list_routes(routes, account_scope) do
      {:ok, %{subscriptions: subscriptions, page: page}}
    end
  end

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
        next_cursor: next_cursor(routes, has_more)
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
    MemberPoloBoundary.transact(account_scope, route, fn repo, polo ->
      {:ok, list_contracts(repo, account_scope.user.id, polo)}
    end)
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

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_route} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_route}}
    else
      :error -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_page_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_limit(_limit), do: :error

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) do
    with {:ok, <<unix_microsecond::signed-64, polo_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, first_contract_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, polo_id} <- Ecto.UUID.load(polo_id_binary) do
      {:ok, %{first_contract_at: first_contract_at, polo_id: polo_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_routes, false), do: nil

  defp next_cursor(routes, true) do
    %{first_contract_at: first_contract_at, polo_id: polo_id} = List.last(routes)
    unix_microsecond = DateTime.to_unix(first_contract_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(polo_id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
