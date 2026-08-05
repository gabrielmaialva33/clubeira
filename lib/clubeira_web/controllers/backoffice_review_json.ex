defmodule ClubeiraWeb.BackofficeReviewJSON do
  @moduledoc false

  def index(%{reviews: reviews, page: page}) do
    %{data: Enum.map(reviews, &moderation_review/1), page: page}
  end

  def create_action(%{review: review, action: action}) do
    %{
      data: %{
        id: action.id,
        review_id: review.id,
        action: action.action,
        reason: action.reason,
        status: review.status,
        moderated_at: DateTime.to_iso8601(action.occurred_at)
      }
    }
  end

  defp moderation_review(review) do
    %{
      id: review.id,
      place_id: review.place_id,
      author_user_id: review.author_user_id,
      source_redemption_id: review.source_redemption_id,
      verification_kind: review.verification_kind,
      status: review.status,
      revision_number: review.revision_number,
      rating: review.rating,
      title: review.title,
      body: review.body,
      submitted_at: DateTime.to_iso8601(review.submitted_at),
      published_at: optional_iso8601(review.published_at),
      rejected_at: optional_iso8601(review.rejected_at)
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
