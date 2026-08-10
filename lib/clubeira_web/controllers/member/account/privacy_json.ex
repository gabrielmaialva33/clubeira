defmodule ClubeiraWeb.Member.PrivacyJSON do
  @moduledoc false

  def consents(%{consents: consents}), do: %{data: Enum.map(consents, &consent_data/1)}
  def consent(%{consent: consent}), do: %{data: consent_data(consent)}
  def requests(%{requests: requests}), do: %{data: Enum.map(requests, &request_data/1)}
  def request(%{request: request}), do: %{data: request_data(request)}

  defp consent_data(consent) do
    %{
      processing_purpose: %{
        code: consent.processing_purpose.code,
        name: consent.processing_purpose.name,
        legal_basis: consent.processing_purpose.legal_basis,
        current_legal_document_version_id:
          consent.processing_purpose.current_legal_document_version_id
      },
      state: consent.state,
      legal_document_version_id: consent.legal_document_version_id,
      occurred_at: datetime_to_string(consent.occurred_at)
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
