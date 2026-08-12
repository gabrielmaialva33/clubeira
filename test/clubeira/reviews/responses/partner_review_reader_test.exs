defmodule Clubeira.Reviews.PartnerReviewReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "lists only published reviews for currently assigned places and their latest response" do
    fixture = published_review!()
    %{scope: scope} = grant_partner!(fixture)

    assert {:ok, %{reviews: [review], page: %{has_more: false}}} =
             Reviews.list_partner_reviews(scope, %{})

    assert review.id == fixture.submission.review.id
    assert review.place.id == fixture.ids.place
    assert review.rating == 5
    assert review.response == nil
    refute Map.has_key?(review, :author_user_id)

    assert {:ok, response} =
             Reviews.put_partner_response(scope, review.id, %{
               "body" => "Obrigado pela avaliação!",
               "idempotency_key" => "partner-review-reader-response"
             })

    assert {:ok, %{reviews: [%{response: listed_response}]}} =
             Reviews.list_partner_reviews(scope, %{"place_id" => fixture.ids.place})

    assert listed_response.id == response.id
    assert listed_response.body == "Obrigado pela avaliação!"
  end

  test "gets one exact review without trusting the browser collection" do
    fixture = published_review!()
    other_polo = published_review!()
    %{scope: scope} = grant_partner!(fixture)

    assert {:ok, review} =
             Reviews.get_partner_review(scope, fixture.submission.review.id)

    assert review.id == fixture.submission.review.id
    assert review.place.id == fixture.ids.place

    assert {:error, :review_not_found} =
             Reviews.get_partner_review(scope, other_polo.submission.review.id)

    assert {:error, :review_not_found} = Reviews.get_partner_review(scope, "not-a-uuid")
  end

  test "validates filters and does not cross place or polo assignment boundaries" do
    fixture = published_review!()
    other_polo = RedemptionsFixtures.create!()
    %{scope: scope} = grant_partner!(fixture)

    assert {:error, :invalid_pagination} =
             Reviews.list_partner_reviews(scope, %{"after" => "malformed"})

    assert {:error, :place_not_found} =
             Reviews.list_partner_reviews(scope, %{"place_id" => "not-a-uuid"})

    assert {:error, :place_not_found} =
             Reviews.list_partner_reviews(scope, %{"place_id" => other_polo.ids.place})
  end

  test "rechecks the global affiliation before every read" do
    fixture = published_review!()
    %{scope: scope, organization_membership: membership} = grant_partner!(fixture)

    membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    assert {:error, :partner_access_required} = Reviews.list_partner_reviews(scope, %{})
  end

  defp published_review! do
    fixture = ReviewsFixtures.pending_review!()
    moderator = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _review} =
             Reviews.moderate(moderator, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Avaliação adequada para o portal parceiro.",
               idempotency_key: "partner-review-reader-publish-#{uuid7()}"
             })

    fixture
  end

  defp grant_partner!(fixture) do
    admin = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization, trade_name: "Parceiro das avaliações")

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, _access} =
             Directory.grant_partner_access(admin, fixture.ids.place, %{
               "email" => user.email,
               "idempotency_key" => "partner-review-reader-access-#{uuid7()}"
             })

    organization_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: organization.id,
        user_id: user.id
      )

    %{
      organization_membership: organization_membership,
      scope: Scope.new!(fixture.ids.polo, actor_user_id: user.id, request_id: uuid7()),
      user: user
    }
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
