defmodule ClubeiraWeb.ReviewJSON do
  @moduledoc false

  def create(%{review: review, revision: revision}) do
    %{
      data: %{
        id: review.id,
        place_id: review.place_id,
        source_redemption_id: review.source_redemption_id,
        verification_kind: review.verification_kind,
        status: review.status,
        revision_number: revision.revision_number,
        rating: revision.rating,
        title: revision.title,
        body: revision.body,
        submitted_at: DateTime.to_iso8601(review.inserted_at)
      }
    }
  end
end
