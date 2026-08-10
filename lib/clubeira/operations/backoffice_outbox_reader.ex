defmodule Clubeira.Operations.BackofficeOutboxReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @statuses ~w(pending publishing published dead_letter)

  @spec list(Scope.t(), map()) ::
          {:ok, %{messages: [map()], page: map()}}
          | {:error,
             :invalid_outbox_status
             | :invalid_pagination
             | :invalid_topic
             | :operations_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :operations_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, topic} <- parse_topic(Map.get(params, "topic")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, topic, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :operations_admin_required}

  defp list_authorized(repo, scope, status, topic, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_operations, transaction_time(repo)) do
      {:ok, outbox_page(repo, scope, status, topic, pagination)}
    end
  end

  defp outbox_page(repo, scope, status, topic, pagination) do
    query_limit = pagination.limit + 1

    rows =
      OutboxMessage
      |> join(:inner, [message], event in DomainEvent, on: event.id == message.domain_event_id)
      |> where([_message, event], event.polo_id == ^scope.polo_id)
      |> with_status(status)
      |> with_topic(topic)
      |> after_message(pagination.after)
      |> order_by([message], desc: message.inserted_at, desc: message.id)
      |> select([message, event], %{
        id: message.id,
        status: message.status,
        topic: message.topic,
        attempt_count: message.attempt_count,
        available_at: message.available_at,
        published_at: message.published_at,
        recorded_at: message.inserted_at,
        has_error: not is_nil(message.last_error),
        event_type: event.event_type,
        aggregate_type: event.aggregate_type,
        aggregate_id: event.aggregate_id,
        occurred_at: event.occurred_at
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      messages: Enum.map(page_rows, &message_data/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp message_data(row) do
    %{
      id: row.id,
      status: row.status,
      topic: row.topic,
      attempt_count: row.attempt_count,
      available_at: row.available_at,
      published_at: row.published_at,
      recorded_at: row.recorded_at,
      has_error: row.has_error,
      event: %{
        type: row.event_type,
        aggregate_type: row.aggregate_type,
        aggregate_id: row.aggregate_id,
        occurred_at: row.occurred_at
      }
    }
  end

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: where(query, [message], message.status == ^status)

  defp with_topic(query, nil), do: query
  defp with_topic(query, topic), do: where(query, [message], message.topic == ^topic)

  defp after_message(query, nil), do: query

  defp after_message(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [message],
      message.inserted_at < ^recorded_at or
        (message.inserted_at == ^recorded_at and message.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_message} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_message}}
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
    with {:ok, <<unix_microsecond::signed-64, message_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(message_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_messages, false), do: nil

  defp next_cursor(messages, true) do
    %{recorded_at: recorded_at, id: id} = List.last(messages)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_outbox_status}

  defp parse_topic(nil), do: {:ok, nil}

  defp parse_topic(topic) when is_binary(topic) do
    normalized = String.trim(topic)

    if byte_size(normalized) in 1..128 do
      {:ok, normalized}
    else
      {:error, :invalid_topic}
    end
  end

  defp parse_topic(_topic), do: {:error, :invalid_topic}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
