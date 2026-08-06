defmodule Clubeira.Subscriptions.ProductOfferingReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @statuses ~w(draft active paused retired)

  @spec list(Scope.t(), map()) ::
          {:ok, %{product_offerings: [map()], page: map()}}
          | {:error,
             :invalid_pagination
             | :invalid_product_offering_code
             | :invalid_product_offering_status
             | :partner_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, code} <- parse_code(Map.get(params, "code")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, code, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_admin_required}

  defp list_authorized(repo, scope, status, code, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_partners, transaction_time(repo)) do
      {:ok, product_offering_page(repo, scope, status, code, pagination)}
    end
  end

  defp product_offering_page(repo, scope, status, code, pagination) do
    query_limit = pagination.limit + 1

    rows =
      ProductOffering
      |> where([offering], offering.polo_id == ^scope.polo_id)
      |> with_status(status)
      |> with_code(code)
      |> after_product_offering(pagination.after)
      |> order_by([offering], desc: offering.inserted_at, desc: offering.id)
      |> select([offering], %{
        id: offering.id,
        code: offering.code,
        scope_kind: offering.scope_kind,
        sales_channel: offering.sales_channel,
        status: offering.status,
        revision: offering.revision,
        recorded_at: offering.inserted_at
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    versions = latest_versions(repo, scope.polo_id, Enum.map(page_rows, & &1.id))

    %{
      product_offerings:
        Enum.map(page_rows, &Map.put(&1, :latest_version, Map.get(versions, &1.id))),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp latest_versions(_repo, _polo_id, []), do: %{}

  defp latest_versions(repo, polo_id, offering_ids) do
    versions =
      ProductOfferingVersion
      |> where(
        [version],
        version.polo_id == ^polo_id and version.product_offering_id in ^offering_ids
      )
      |> distinct([version], version.product_offering_id)
      |> order_by([version], asc: version.product_offering_id, desc: version.version)
      |> select([version], %{
        id: version.id,
        product_offering_id: version.product_offering_id,
        version: version.version,
        name: version.name,
        description: version.description,
        status: version.status,
        effective_during: version.effective_during,
        activation_policy: version.activation_policy,
        renewal_policy: version.renewal_policy,
        cycle_policy: version.cycle_policy,
        cycle_interval_unit: version.cycle_interval_unit,
        cycle_interval_count: version.cycle_interval_count
      })
      |> repo.all()

    prices = prices_by_version(repo, polo_id, Enum.map(versions, & &1.id))

    Map.new(versions, fn version ->
      data =
        version
        |> Map.delete(:product_offering_id)
        |> Map.put(:prices, Map.get(prices, version.id, []))

      {version.product_offering_id, data}
    end)
  end

  defp prices_by_version(_repo, _polo_id, []), do: %{}

  defp prices_by_version(repo, polo_id, version_ids) do
    OfferingPrice
    |> where(
      [price],
      price.polo_id == ^polo_id and price.product_offering_version_id in ^version_ids
    )
    |> order_by([price],
      asc: price.product_offering_version_id,
      asc: price.price_key,
      asc: price.id
    )
    |> select([price], %{
      id: price.id,
      product_offering_version_id: price.product_offering_version_id,
      key: price.price_key,
      currency: price.currency,
      amount: price.amount,
      billing_model: price.billing_model,
      interval_unit: price.billing_interval_unit,
      interval_count: price.billing_interval_count,
      installments: price.installments,
      valid_during: price.valid_during
    })
    |> repo.all()
    |> Enum.group_by(
      & &1.product_offering_version_id,
      &Map.delete(&1, :product_offering_version_id)
    )
  end

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: where(query, [offering], offering.status == ^status)

  defp with_code(query, nil), do: query
  defp with_code(query, code), do: where(query, [offering], offering.code == ^code)

  defp after_product_offering(query, nil), do: query

  defp after_product_offering(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [offering],
      offering.inserted_at < ^recorded_at or
        (offering.inserted_at == ^recorded_at and offering.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_offering} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_offering}}
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
    with {:ok, <<unix_microsecond::signed-64, offering_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, offering_id} <- Ecto.UUID.load(offering_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: offering_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_offerings, false), do: nil

  defp next_cursor(offerings, true) do
    %{recorded_at: recorded_at, id: id} = List.last(offerings)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_product_offering_status}

  defp parse_code(nil), do: {:ok, nil}

  defp parse_code(code) when is_binary(code) do
    normalized = String.trim(code)

    if byte_size(normalized) in 2..80 do
      {:ok, normalized}
    else
      {:error, :invalid_product_offering_code}
    end
  end

  defp parse_code(_code), do: {:error, :invalid_product_offering_code}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
