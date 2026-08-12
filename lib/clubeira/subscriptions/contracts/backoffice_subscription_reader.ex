defmodule Clubeira.Subscriptions.BackofficeSubscriptionReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @subscription_statuses ~w(pending active past_due suspended cancelled expired)

  @type page :: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}

  @spec list(Scope.t(), map()) ::
          {:ok, %{subscriptions: [map()], page: page()}}
          | {:error,
             :billing_admin_required
             | :invalid_order_number
             | :invalid_pagination
             | :invalid_subscription_filter
             | :invalid_subscription_status
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :billing_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, filters} <- parse_filters(params) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, filters, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :billing_admin_required}

  @spec get(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()}
          | {:error, :access_contract_not_found | :billing_admin_required | term()}
  def get(%Scope{actor_user_id: nil}, _contract_id), do: {:error, :billing_admin_required}

  def get(%Scope{} = scope, contract_id) do
    with {:ok, contract_id} <- cast_contract_id(contract_id) do
      Repo.transact_in_polo(
        scope,
        &get_authorized(&1, scope, contract_id)
      )
    end
  end

  def get(_scope, _contract_id), do: {:error, :billing_admin_required}

  defp list_authorized(repo, scope, filters, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_billing, transaction_time(repo)) do
      {:ok, subscription_page(repo, scope, filters, pagination)}
    end
  end

  defp get_authorized(repo, scope, contract_id) do
    with :ok <- Authorization.authorize(repo, scope, :manage_billing, transaction_time(repo)) do
      subscription =
        scope
        |> base_subscriptions_query()
        |> where([contract: contract], contract.id == ^contract_id)
        |> select_subscription()
        |> repo.one()
        |> empty_cycle_to_nil()

      if subscription,
        do: {:ok, subscription},
        else: {:error, :access_contract_not_found}
    end
  end

  defp subscription_page(repo, scope, filters, pagination) do
    rows =
      scope
      |> subscriptions_query(filters, pagination)
      |> select_subscription()
      |> repo.all()
      |> Enum.map(&empty_cycle_to_nil/1)

    {subscriptions, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      subscriptions: subscriptions,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(subscriptions, has_more)
      }
    }
  end

  defp subscriptions_query(scope, filters, pagination) do
    query_limit = pagination.limit + 1

    scope
    |> base_subscriptions_query()
    |> with_status(filters.status)
    |> with_order_number(filters.order_number)
    |> with_purchaser(filters.purchaser_user_id)
    |> with_product_offering_version(filters.product_offering_version_id)
    |> after_contract(pagination.after)
    |> order_by([contract: contract], desc: contract.inserted_at, desc: contract.id)
    |> limit(^query_limit)
  end

  defp base_subscriptions_query(scope) do
    AccessContract
    |> from(as: :contract)
    |> join_order_item()
    |> join_order()
    |> join_offering()
    |> join_current_cycle()
    |> join_current_balance()
    |> where([contract: contract], contract.polo_id == ^scope.polo_id)
  end

  defp join_order_item(query) do
    join(query, :inner, [contract: contract], item in OrderItem,
      as: :item,
      on:
        item.id == contract.order_item_id and
          item.polo_id == contract.polo_id and
          item.product_offering_version_id == contract.product_offering_version_id
    )
  end

  defp join_order(query) do
    join(query, :inner, [contract: contract, item: item], order in Order,
      as: :order,
      on: order.id == item.order_id and order.polo_id == contract.polo_id
    )
  end

  defp join_offering(query) do
    join(query, :inner, [contract: contract], offering in ProductOfferingVersion,
      as: :offering,
      on:
        offering.id == contract.product_offering_version_id and
          offering.polo_id == contract.polo_id
    )
  end

  defp join_current_cycle(query) do
    join(query, :left, [contract: contract], cycle in BenefitCycle,
      as: :cycle,
      on:
        cycle.access_contract_id == contract.id and
          cycle.polo_id == contract.polo_id and
          cycle.status == "active" and
          fragment("? @> statement_timestamp()", cycle.benefits_during)
    )
  end

  defp join_current_balance(query) do
    join(query, :left, [cycle: cycle], balance in subquery(balance_query()),
      as: :balance,
      on:
        balance.polo_id == cycle.polo_id and
          balance.access_contract_id == cycle.access_contract_id and
          balance.benefit_cycle_id == cycle.id
    )
  end

  defp select_subscription(query) do
    select(
      query,
      [contract: contract, order: order, offering: offering, cycle: cycle, balance: balance],
      %{
        id: contract.id,
        status: contract.status,
        purchaser_user_id: contract.purchaser_user_id,
        starts_at: contract.starts_at,
        activated_at: contract.activated_at,
        ends_at: contract.ends_at,
        cancelled_at: contract.cancelled_at,
        recorded_at: contract.inserted_at,
        order: %{
          id: order.id,
          order_number: order.order_number,
          status: order.status,
          placed_at: order.placed_at
        },
        offering: %{
          version_id: offering.id,
          version: offering.version,
          name: offering.name,
          renewal_policy: offering.renewal_policy,
          cycle: %{
            policy: offering.cycle_policy,
            interval_unit: offering.cycle_interval_unit,
            interval_count: offering.cycle_interval_count
          }
        },
        current_cycle: %{
          id: cycle.id,
          sequence: cycle.sequence,
          status: cycle.status,
          starts_at: fragment("lower(?)", cycle.benefits_during),
          ends_at: fragment("upper(?)", cycle.benefits_during)
        },
        balance: %{
          issued_units: coalesce(balance.issued_units, 0),
          available_units: coalesce(balance.available_units, 0),
          consumed_units: coalesce(balance.issued_units - balance.available_units, 0)
        }
      }
    )
  end

  defp with_status(query, nil), do: query

  defp with_status(query, status) do
    where(query, [contract: contract], contract.status == ^status)
  end

  defp with_order_number(query, nil), do: query

  defp with_order_number(query, order_number) do
    where(query, [order: order], order.order_number == ^order_number)
  end

  defp with_purchaser(query, nil), do: query

  defp with_purchaser(query, purchaser_user_id) do
    where(query, [contract: contract], contract.purchaser_user_id == ^purchaser_user_id)
  end

  defp with_product_offering_version(query, nil), do: query

  defp with_product_offering_version(query, product_offering_version_id) do
    where(
      query,
      [contract: contract],
      contract.product_offering_version_id == ^product_offering_version_id
    )
  end

  defp after_contract(query, nil), do: query

  defp after_contract(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [contract: contract],
      contract.inserted_at < ^recorded_at or
        (contract.inserted_at == ^recorded_at and contract.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_contract} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_contract}}
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

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, <<unix_microsecond::signed-64, contract_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, contract_id} <- Ecto.UUID.load(contract_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: contract_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_subscriptions, false), do: nil

  defp next_cursor(subscriptions, true) do
    %{recorded_at: recorded_at, id: id} = List.last(subscriptions)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @subscription_statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_subscription_status}

  defp parse_filters(params) do
    with {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, order_number} <- parse_order_number(Map.get(params, "order_number")),
         {:ok, purchaser_user_id} <-
           parse_uuid_filter(Map.get(params, "purchaser_user_id")),
         {:ok, product_offering_version_id} <-
           parse_uuid_filter(Map.get(params, "product_offering_version_id")) do
      {:ok,
       %{
         status: status,
         order_number: order_number,
         purchaser_user_id: purchaser_user_id,
         product_offering_version_id: product_offering_version_id
       }}
    end
  end

  defp parse_order_number(nil), do: {:ok, nil}

  defp parse_order_number(order_number) when is_binary(order_number) do
    normalized = String.trim(order_number)

    if byte_size(normalized) in 1..128 do
      {:ok, normalized}
    else
      {:error, :invalid_order_number}
    end
  end

  defp parse_order_number(_order_number), do: {:error, :invalid_order_number}

  defp parse_uuid_filter(nil), do: {:ok, nil}

  defp parse_uuid_filter(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_subscription_filter}
    end
  end

  defp parse_uuid_filter(_value), do: {:error, :invalid_subscription_filter}

  defp cast_contract_id(contract_id) do
    case Ecto.UUID.cast(contract_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :access_contract_not_found}
    end
  end

  defp balance_query do
    EntitlementAllocation
    |> join(:inner, [allocation], subject in CycleEntitlementSubject,
      on:
        subject.id == allocation.cycle_entitlement_subject_id and
          subject.polo_id == allocation.polo_id
    )
    |> group_by([allocation, subject], [
      allocation.polo_id,
      subject.access_contract_id,
      subject.benefit_cycle_id
    ])
    |> select([allocation, subject], %{
      polo_id: allocation.polo_id,
      access_contract_id: subject.access_contract_id,
      benefit_cycle_id: subject.benefit_cycle_id,
      issued_units: sum(allocation.issued_units),
      available_units: sum(allocation.available_units)
    })
  end

  defp empty_cycle_to_nil(%{current_cycle: %{id: nil}} = subscription) do
    %{subscription | current_cycle: nil}
  end

  defp empty_cycle_to_nil(subscription), do: subscription

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
