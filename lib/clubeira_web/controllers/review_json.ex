defmodule ClubeiraWeb.ReviewJSON do
  @moduledoc false

  def index(%{reviews: reviews, page: page}) do
    %{data: Enum.map(reviews, &public_review/1), page: page}
  end

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

  defp public_review(review) do
    %{
      id: review.id,
      place_id: review.place_id,
      verification_kind: review.verification_kind,
      revision_number: review.revision_number,
      rating: review.rating,
      title: review.title,
      body: review.body,
      published_at: DateTime.to_iso8601(review.published_at)
    }
  end
end
