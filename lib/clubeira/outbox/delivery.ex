defmodule Clubeira.Outbox.Delivery do
  @moduledoc """
  Claims and delivers one tenant batch without holding database locks during I/O.
  """

  import Ecto.Query

  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_batch_size 50
  @default_lock_timeout_ms 60_000
  @default_max_attempts 10
  @default_retry_base_ms 1_000
  @default_retry_max_ms 3_600_000

  @spec run_once(Scope.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run_once(%Scope{} = scope, options) when is_list(options) do
    config = config!(options)

    with {:ok, messages} <- claim(scope, config) do
      Enum.each(messages, &deliver(scope, &1, config))
      {:ok, length(messages)}
    end
  end

  defp claim(scope, config) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)
      stale_before = DateTime.add(now, -config.lock_timeout_ms, :millisecond)

      messages =
        repo.all(
          from message in OutboxMessage,
            where:
              (message.status == "pending" and message.available_at <= ^now) or
                (message.status == "publishing" and message.locked_at < ^stale_before),
            order_by: [asc: message.available_at, asc: message.id],
            limit: ^config.batch_size,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      ids = Enum.map(messages, & &1.id)

      if ids != [] do
        {count, _messages} =
          repo.update_all(
            from(message in OutboxMessage, where: message.id in ^ids),
            set: [
              status: "publishing",
              locked_at: now,
              locked_by: config.worker_id,
              last_error: nil,
              updated_at: now
            ],
            inc: [attempt_count: 1]
          )

        if count != length(ids), do: raise("outbox claim count changed under row lock")
      end

      claimed =
        if ids == [] do
          []
        else
          repo.all(
            from message in OutboxMessage,
              where: message.id in ^ids,
              order_by: [asc: message.available_at, asc: message.id]
          )
        end

      {:ok, claimed}
    end)
  end

  defp deliver(scope, message, config) do
    outcome = safely_publish(config.adapter, message, config.adapter_options)

    case outcome do
      :ok -> finalize_success(scope, message, config)
      {:error, reason} -> finalize_failure(scope, message, reason, config)
    end
  end

  defp safely_publish(adapter, message, options) do
    adapter.publish(message, options)
  rescue
    error -> {:error, {:adapter_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:adapter_throw, kind}}
  end

  defp finalize_success(scope, message, config) do
    {:ok, :published} =
      Repo.transact_in_polo(scope, fn repo ->
        now = transaction_time(repo)

        {count, _messages} =
          repo.update_all(
            owned_claim(message.id, config.worker_id),
            set: [
              status: "published",
              published_at: now,
              locked_at: nil,
              locked_by: nil,
              last_error: nil,
              updated_at: now
            ]
          )

        if count == 1, do: {:ok, :published}, else: {:error, :outbox_claim_lost}
      end)

    telemetry(:published, message, %{})
  end

  defp finalize_failure(scope, message, reason, config) do
    {:ok, terminal_status} =
      Repo.transact_in_polo(scope, fn repo ->
        now = transaction_time(repo)
        dead_letter? = message.attempt_count >= config.max_attempts
        status = if(dead_letter?, do: "dead_letter", else: "pending")

        available_at =
          if dead_letter? do
            message.available_at
          else
            DateTime.add(now, retry_delay_ms(message.attempt_count, config), :millisecond)
          end

        {count, _messages} =
          repo.update_all(
            owned_claim(message.id, config.worker_id),
            set: [
              status: status,
              available_at: available_at,
              locked_at: nil,
              locked_by: nil,
              last_error: safe_error(reason),
              updated_at: now
            ]
          )

        if count == 1, do: {:ok, status}, else: {:error, :outbox_claim_lost}
      end)

    telemetry(:failed, message, %{status: terminal_status})
  end

  defp owned_claim(message_id, worker_id) do
    from message in OutboxMessage,
      where:
        message.id == ^message_id and message.status == "publishing" and
          message.locked_by == ^worker_id
  end

  defp retry_delay_ms(attempt_count, config) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(config.retry_base_ms * Integer.pow(2, exponent), config.retry_max_ms)
  end

  defp safe_error({:http_status, status}) when is_integer(status), do: "http_status:#{status}"
  defp safe_error({:transport, reason}) when is_atom(reason), do: "transport:#{reason}"
  defp safe_error({:adapter_exception, module}) when is_atom(module), do: "exception:#{module}"
  defp safe_error({:adapter_throw, kind}) when is_atom(kind), do: "throw:#{kind}"
  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(_reason), do: "adapter_error"

  defp telemetry(outcome, message, metadata) do
    :telemetry.execute(
      [:clubeira, :outbox, outcome],
      %{count: 1, attempt_count: message.attempt_count},
      Map.merge(%{message_id: message.id, topic: message.topic}, metadata)
    )
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp config!(options) do
    %{
      adapter: Keyword.fetch!(options, :adapter),
      adapter_options: Keyword.get(options, :adapter_options, []),
      worker_id: Keyword.fetch!(options, :worker_id),
      batch_size: positive_integer!(options, :batch_size, @default_batch_size),
      lock_timeout_ms: positive_integer!(options, :lock_timeout_ms, @default_lock_timeout_ms),
      max_attempts: positive_integer!(options, :max_attempts, @default_max_attempts),
      retry_base_ms: positive_integer!(options, :retry_base_ms, @default_retry_base_ms),
      retry_max_ms: positive_integer!(options, :retry_max_ms, @default_retry_max_ms)
    }
  end

  defp positive_integer!(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
