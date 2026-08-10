defmodule ClubeiraWeb.Partner.ReviewResponseJSON do
  @moduledoc false

  def show(%{response: response}) do
    %{
      data: %{
        id: response.id,
        review_id: response.review_id,
        organization: response.organization,
        status: response.status,
        revision_number: response.revision_number,
        body: response.body,
        published_at: DateTime.to_iso8601(response.published_at),
        updated_at: DateTime.to_iso8601(response.updated_at)
      }
    }
  end
end
