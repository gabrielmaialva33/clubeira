defmodule Clubeira.Billing.OrderReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @spec list(Scope.t(), map()) ::
          {:ok, %{orders: [map()], page: map()}}
          | {:error, :actor_required | :invalid_pagination | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :actor_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params) do
      Repo.transact_in_polo(scope, fn repo ->
        {:ok, list_in_scope(repo, scope, pagination)}
      end)
    end
  end

  def list(_scope, _params), do: {:error, :actor_required}

  defp list_in_scope(repo, scope, pagination) do
    query_limit = pagination.limit + 1

    rows =
      Order
      |> where([order], order.polo_id == ^scope.polo_id)
      |> where([order], order.purchaser_user_id == ^scope.actor_user_id)
      |> after_order(pagination.after)
      |> order_by([order], desc: order.inserted_at, desc: order.id)
      |> select_order()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    items_by_order = list_items(repo, scope.polo_id, Enum.map(page_rows, & &1.id))

    orders =
      Enum.map(page_rows, fn order ->
        Map.put(order, :items, Map.get(items_by_order, order.id, []))
      end)

    %{
      orders: orders,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp select_order(query) do
    select(query, [order], %{
      id: order.id,
      order_number: order.order_number,
      status: order.status,
      currency: order.currency,
      subtotal_amount: order.subtotal_amount,
      discount_amount: order.discount_amount,
      total_amount: order.total_amount,
      placed_at: order.placed_at,
      cancelled_at: order.cancelled_at,
      inserted_at: order.inserted_at
    })
  end

  defp list_items(_repo, _polo_id, []), do: %{}

  defp list_items(repo, polo_id, order_ids) do
    OrderItem
    |> join(:inner, [item], version in ProductOfferingVersion,
      on:
        version.id == item.product_offering_version_id and
          version.polo_id == item.polo_id
    )
    |> where([item], item.polo_id == ^polo_id)
    |> where([item], item.order_id in ^order_ids)
    |> order_by([item], asc: item.order_id, asc: item.inserted_at, asc: item.id)
    |> select([item, version], %{
      id: item.id,
      order_id: item.order_id,
      product_offering_version_id: item.product_offering_version_id,
      offering_price_id: item.offering_price_id,
      name: version.name,
      description: version.description,
      quantity: item.quantity,
      unit_amount: item.unit_amount,
      total_amount: item.total_amount
    })
    |> repo.all()
    |> Enum.group_by(& &1.order_id, &Map.delete(&1, :order_id))
  end

  defp after_order(query, nil), do: query

  defp after_order(query, %{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [order],
      order.inserted_at < ^inserted_at or
        (order.inserted_at == ^inserted_at and order.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_order} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_order}}
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
    with {:ok, <<unix_microsecond::signed-64, order_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, inserted_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, order_id} <- Ecto.UUID.load(order_id_binary) do
      {:ok, %{inserted_at: inserted_at, id: order_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_orders, false), do: nil

  defp next_cursor(orders, true) do
    %{inserted_at: inserted_at, id: id} = List.last(orders)
    unix_microsecond = DateTime.to_unix(inserted_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
