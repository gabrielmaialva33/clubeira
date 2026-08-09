defmodule ClubeiraWeb.ReviewJSON do
  @moduledoc false

  def index(%{reviews: reviews, page: page, polo_slug: polo_slug}) do
    %{data: Enum.map(reviews, &public_review(&1, polo_slug)), page: page}
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

  defp public_review(review, polo_slug) do
    %{
      id: review.id,
      place_id: review.place_id,
      verification_kind: review.verification_kind,
      revision_number: review.revision_number,
      rating: review.rating,
      title: review.title,
      body: review.body,
      published_at: DateTime.to_iso8601(review.published_at),
      response: public_response(review.response),
      media: Enum.map(review.media, &public_media(&1, polo_slug))
    }
  end

  defp public_response(nil), do: nil

  defp public_response(response) do
    %{
      id: response.id,
      organization: response.organization,
      status: response.status,
      revision_number: response.revision_number,
      body: response.body,
      published_at: DateTime.to_iso8601(response.published_at),
      updated_at: DateTime.to_iso8601(response.updated_at)
    }
  end

  defp public_media(media, polo_slug) do
    media
    |> Map.put(:href, "/api/v1/polos/#{polo_slug}/review-media/#{media.id}")
  end
end
