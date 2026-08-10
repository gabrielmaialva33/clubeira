defmodule Clubeira.Operations.OutboxRetry do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Operations.OutboxRetryRequest
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "operations.retry_outbox_message"

  @spec retry(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def retry(%Scope{actor_user_id: nil}, _message_id, _attributes),
    do: {:error, :operations_admin_required}

  def retry(%Scope{} = scope, message_id, attributes) when is_map(attributes) do
    with {:ok, message_id} <- cast_message_id(message_id),
         {:ok, request} <- OutboxRetryRequest.new(attributes) do
      transact_retry(scope, message_id, request)
    end
  end

  def retry(_scope, _message_id, _attributes), do: {:error, :operations_admin_required}

  defp transact_retry(scope, message_id, request) do
    Repo.transact_in_polo(
      scope,
      &retry_in_transaction(&1, scope, message_id, request)
    )
  end

  defp retry_in_transaction(repo, scope, message_id, request) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_operations, now) do
      retry_authorized(repo, scope, message_id, request, now)
    end
  end

  defp retry_authorized(repo, scope, message_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, message_id),
           now
         ) do
      {:new, idempotency_id} ->
        retry_new(repo, scope, message_id, idempotency_id, now)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_new(repo, scope, message_id, idempotency_id, now) do
    with {:ok, message} <- lock_message(repo, scope, message_id),
         :ok <- ensure_dead_letter(message) do
      requeued = requeue!(repo, message, now)
      result = response_data(requeued, now)

      Audit.record_tenant!(repo, scope, %{
        action: "outbox.message_requeued",
        resource_type: "outbox_message",
        resource_id: message.id,
        metadata: %{
          "previous_attempt_count" => message.attempt_count,
          "topic" => message.topic
        },
        occurred_at: now
      })

      Idempotency.complete!(
        repo,
        idempotency_id,
        "outbox_message",
        message.id,
        result,
        now,
        response_status: 200
      )

      {:ok, result}
    end
  end

  defp lock_message(repo, scope, message_id) do
    message =
      OutboxMessage
      |> join(:inner, [message], event in DomainEvent, on: event.id == message.domain_event_id)
      |> where(
        [message, event],
        message.id == ^message_id and event.polo_id == ^scope.polo_id
      )
      |> select([message], message)
      |> lock("FOR UPDATE")
      |> repo.one()

    if message, do: {:ok, message}, else: {:error, :outbox_message_not_found}
  end

  defp ensure_dead_letter(%OutboxMessage{status: "dead_letter"}), do: :ok
  defp ensure_dead_letter(%OutboxMessage{}), do: {:error, :outbox_message_not_retryable}

  defp requeue!(repo, message, now) do
    message
    |> Ecto.Changeset.change(
      status: "pending",
      attempt_count: 0,
      available_at: now,
      locked_at: nil,
      locked_by: nil,
      published_at: nil,
      last_error: nil,
      updated_at: now
    )
    |> repo.update!()
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "outbox_message",
         response_body:
           %{
             "id" => id,
             "status" => "pending",
             "attempt_count" => 0,
             "available_at" => available_at,
             "requeued_at" => requeued_at
           } = response
       })
       when is_binary(id) and is_binary(available_at) and is_binary(requeued_at),
       do: {:ok, response}

  defp replay(key), do: raise("invalid persisted outbox retry response: #{inspect(key)}")

  defp response_data(message, now) do
    timestamp = DateTime.to_iso8601(now)

    %{
      "id" => message.id,
      "status" => message.status,
      "attempt_count" => message.attempt_count,
      "available_at" => DateTime.to_iso8601(message.available_at),
      "requeued_at" => timestamp
    }
  end

  defp request_hash(scope, message_id) do
    Idempotency.fingerprint({1, scope.polo_id, scope.actor_user_id, message_id})
  end

  defp cast_message_id(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :outbox_message_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
