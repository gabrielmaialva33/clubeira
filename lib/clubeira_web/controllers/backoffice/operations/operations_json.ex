defmodule ClubeiraWeb.Backoffice.OperationsJSON do
  @moduledoc false

  def outbox_messages(%{messages: messages, page: page}) do
    %{
      data: Enum.map(messages, &outbox_message_data/1),
      meta: %{count: length(messages), page: page}
    }
  end

  def audit_events(%{events: events, page: page}) do
    %{
      data: Enum.map(events, &audit_event_data/1),
      meta: %{count: length(events), page: page}
    }
  end

  def retry_outbox_message(%{result: result}), do: %{data: result}

  defp audit_event_data(event) do
    %{
      id: event.id,
      actor_user_id: event.actor_user_id,
      actor_kind: event.actor_kind,
      action: event.action,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      request_id: event.request_id,
      correlation_id: event.correlation_id,
      occurred_at: datetime_to_string(event.occurred_at),
      recorded_at: datetime_to_string(event.recorded_at)
    }
  end

  defp outbox_message_data(message) do
    %{
      id: message.id,
      status: message.status,
      topic: message.topic,
      attempt_count: message.attempt_count,
      available_at: datetime_to_string(message.available_at),
      published_at: datetime_to_string(message.published_at),
      recorded_at: datetime_to_string(message.recorded_at),
      has_error: message.has_error,
      event: %{
        type: message.event.type,
        aggregate_type: message.event.aggregate_type,
        aggregate_id: message.event.aggregate_id,
        occurred_at: datetime_to_string(message.event.occurred_at)
      }
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
