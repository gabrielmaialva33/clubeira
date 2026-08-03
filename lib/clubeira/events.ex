defmodule Clubeira.Events do
  @moduledoc """
  Transactional boundary for domain events and their outbox messages.

  Every emitted event is persisted together with a durable publication envelope.
  Delivery happens only after the surrounding transaction commits.
  """

  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage

  @required_attributes ~w(
    polo_id
    aggregate_type
    aggregate_id
    aggregate_version
    event_type
    topic
    message_key
    payload
    occurred_at
  )a

  @spec emit!(module(), map()) :: DomainEvent.t()
  def emit!(repo, attributes) when is_map(attributes) do
    ensure_transaction!(repo)
    Enum.each(@required_attributes, &Map.fetch!(attributes, &1))

    event = append_domain_event!(repo, attributes)
    enqueue_outbox_message!(repo, event, attributes)
    event
  end

  defp append_domain_event!(repo, attributes) do
    %DomainEvent{
      polo_id: attributes.polo_id,
      aggregate_type: attributes.aggregate_type,
      aggregate_id: attributes.aggregate_id,
      aggregate_version: attributes.aggregate_version,
      event_type: attributes.event_type,
      payload: attributes.payload,
      metadata: Map.get(attributes, :metadata, %{}),
      occurred_at: attributes.occurred_at,
      inserted_at: attributes.occurred_at
    }
    |> repo.insert!()
  end

  defp enqueue_outbox_message!(repo, event, attributes) do
    %OutboxMessage{
      domain_event_id: event.id,
      topic: attributes.topic,
      message_key: attributes.message_key,
      payload: outbox_payload(event),
      status: "pending",
      attempt_count: 0,
      available_at: event.occurred_at,
      inserted_at: event.occurred_at,
      updated_at: event.occurred_at
    }
    |> repo.insert!()
  end

  defp outbox_payload(event) do
    %{
      "event_id" => event.id,
      "event_type" => event.event_type,
      "polo_id" => event.polo_id,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "data" => event.payload
    }
  end

  defp ensure_transaction!(repo) do
    unless repo.in_transaction?() do
      raise ArgumentError, "domain events must be emitted inside a database transaction"
    end
  end
end
