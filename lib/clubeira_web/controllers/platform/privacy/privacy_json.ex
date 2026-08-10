defmodule ClubeiraWeb.Platform.PrivacyJSON do
  @moduledoc false

  def processing_purposes(%{purposes: purposes}) do
    %{data: Enum.map(purposes, &processing_purpose_data/1)}
  end

  def processing_purpose(%{purpose: purpose}), do: %{data: processing_purpose_data(purpose)}

  def requests(%{requests: requests, page: page}) do
    %{data: Enum.map(requests, &request_data/1), page: page}
  end

  def request(%{request: request}), do: %{data: request_data(request)}

  defp processing_purpose_data(purpose) do
    %{
      id: purpose.id,
      code: purpose.code,
      name: purpose.name,
      legal_basis: purpose.legal_basis,
      legal_document_version_id: purpose.legal_document_version_id,
      status: purpose.status,
      inserted_at: DateTime.to_iso8601(purpose.inserted_at),
      updated_at: DateTime.to_iso8601(purpose.updated_at)
    }
  end

  defp request_data(request) do
    %{
      id: request.id,
      client_request_id: request.client_request_id,
      request_type: request.request_type,
      status: request.status,
      due_at: DateTime.to_iso8601(request.due_at),
      completed_at: datetime_to_string(request.completed_at),
      rejection_reason: request.rejection_reason,
      inserted_at: DateTime.to_iso8601(request.inserted_at),
      updated_at: DateTime.to_iso8601(request.updated_at),
      events: Enum.map(request.events, &request_event_data/1)
    }
  end

  defp request_event_data(event) do
    %{
      event_type: event.event_type,
      payload: event.payload,
      occurred_at: DateTime.to_iso8601(event.occurred_at)
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(datetime), do: DateTime.to_iso8601(datetime)
end
