defmodule Clubeira.Operations.BackofficeAuditReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @spec list(Scope.t(), map()) ::
          {:ok, %{events: [map()], page: map()}}
          | {:error,
             :invalid_action
             | :invalid_pagination
             | :invalid_resource_type
             | :operations_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :operations_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, action} <- parse_identifier(Map.get(params, "action"), :invalid_action),
         {:ok, resource_type} <-
           parse_identifier(Map.get(params, "resource_type"), :invalid_resource_type) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, action, resource_type, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :operations_admin_required}

  defp list_authorized(repo, scope, action, resource_type, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_operations, transaction_time(repo)) do
      {:ok, audit_page(repo, scope, action, resource_type, pagination)}
    end
  end

  defp audit_page(repo, scope, action, resource_type, pagination) do
    query_limit = pagination.limit + 1

    rows =
      TenantEvent
      |> where([event], event.polo_id == ^scope.polo_id)
      |> with_action(action)
      |> with_resource_type(resource_type)
      |> after_event(pagination.after)
      |> order_by([event], desc: event.occurred_at, desc: event.id)
      |> select([event], %{
        id: event.id,
        actor_user_id: event.actor_user_id,
        actor_kind: event.actor_kind,
        action: event.action,
        resource_type: event.resource_type,
        resource_id: event.resource_id,
        request_id: event.request_id,
        correlation_id: event.correlation_id,
        occurred_at: event.occurred_at,
        recorded_at: event.inserted_at
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      events: page_rows,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp with_action(query, nil), do: query
  defp with_action(query, action), do: where(query, [event], event.action == ^action)

  defp with_resource_type(query, nil), do: query

  defp with_resource_type(query, resource_type),
    do: where(query, [event], event.resource_type == ^resource_type)

  defp after_event(query, nil), do: query

  defp after_event(query, %{occurred_at: occurred_at, id: id}) do
    where(
      query,
      [event],
      event.occurred_at < ^occurred_at or
        (event.occurred_at == ^occurred_at and event.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_event} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_event}}
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
    with {:ok, <<unix_microsecond::signed-64, event_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, occurred_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(event_id_binary) do
      {:ok, %{occurred_at: occurred_at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_events, false), do: nil

  defp next_cursor(events, true) do
    %{occurred_at: occurred_at, id: id} = List.last(events)
    unix_microsecond = DateTime.to_unix(occurred_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_identifier(nil, _error), do: {:ok, nil}

  defp parse_identifier(value, error) when is_binary(value) do
    normalized = String.trim(value)

    if byte_size(normalized) in 1..128 do
      {:ok, normalized}
    else
      {:error, error}
    end
  end

  defp parse_identifier(_value, error), do: {:error, error}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
