defmodule Clubeira.Reviews.ReviewReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  test "gets one exact published review only inside its public polo place" do
    fixture = published_review!()

    assert {:ok, review} =
             Reviews.get_public(
               fixture.scope,
               fixture.ids.place,
               fixture.submission.review.id
             )

    assert review.id == fixture.submission.review.id
    assert review.place_id == fixture.ids.place
    assert review.rating == 5
    assert review.body == "O benefício foi entregue como anunciado."
    assert review.response == nil
    assert review.media == []

    assert {:error, :review_not_found} =
             Reviews.get_public(
               fixture.scope,
               fixture.ids.other_place,
               fixture.submission.review.id
             )

    other = published_review!()

    assert {:error, :review_not_found} =
             Reviews.get_public(
               other.scope,
               other.ids.place,
               fixture.submission.review.id
             )
  end

  test "does not return pending reviews or malformed identities" do
    fixture = ReviewsFixtures.pending_review!()

    assert {:error, :review_not_found} =
             Reviews.get_public(
               fixture.scope,
               fixture.ids.place,
               fixture.submission.review.id
             )

    assert {:error, :review_not_found} =
             Reviews.get_public(fixture.scope, fixture.ids.place, "not-a-uuid")
  end

  defp published_review! do
    fixture = ReviewsFixtures.pending_review!(alternate_validation_place: true)
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _result} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-reader-#{uuid7()}"
             })

    fixture
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
