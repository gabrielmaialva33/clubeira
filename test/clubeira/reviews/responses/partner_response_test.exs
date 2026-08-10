defmodule Clubeira.Reviews.PartnerResponseTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "an assigned partner publishes and revises one public response append-only" do
    fixture = published_review_fixture!()
    %{organization: organization, scope: partner_scope} = partner_access!(fixture)
    review_id = fixture.submission.review.id

    first_request = %{
      "body" => "Obrigado pela avaliação. Ficamos felizes com sua experiência!",
      "idempotency_key" => "partner-review-response-#{uuid7()}"
    }

    assert {:ok, first} =
             Reviews.put_partner_response(partner_scope, review_id, first_request)

    assert first.review_id == review_id
    assert first.organization == %{id: organization.id, name: organization.trade_name}
    assert first.revision_number == 1
    assert first.body == first_request["body"]
    assert first.status == "published"

    assert {:ok, ^first} =
             Reviews.put_partner_response(partner_scope, review_id, first_request)

    assert {:ok, same_body} =
             Reviews.put_partner_response(partner_scope, review_id, %{
               "body" => first_request["body"],
               "idempotency_key" => "partner-review-response-same-body-#{uuid7()}"
             })

    assert same_body.revision_number == 1

    assert {:error, :idempotency_conflict} =
             Reviews.put_partner_response(partner_scope, review_id, %{
               first_request
               | "body" => "Conteúdo divergente para a mesma chave."
             })

    second_request = %{
      "body" => "Obrigado pela avaliação. A equipe já recebeu seu elogio!",
      "idempotency_key" => "partner-review-response-edit-#{uuid7()}"
    }

    assert {:ok, second} =
             Reviews.put_partner_response(partner_scope, review_id, second_request)

    assert second.id == first.id
    assert second.revision_number == 2
    assert second.body == second_request["body"]

    assert {:ok, %{reviews: [public_review]}} =
             Reviews.list_public(fixture.scope, fixture.ids.place, %{})

    assert public_review.response == second

    assert %{rows: [[1, 2, 2, 2, 2]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM review_responses WHERE review_id = $1),
                 (SELECT count(*) FROM review_response_revisions AS revision
                  JOIN review_responses AS response ON response.id = revision.review_response_id
                  WHERE response.review_id = $1),
                 (SELECT count(*) FROM domain_events
                  WHERE aggregate_type = 'review_response'
                    AND event_type IN ('review_response.published', 'review_response.updated')),
                 (SELECT count(*) FROM outbox_messages AS message
                  JOIN domain_events AS event ON event.id = message.domain_event_id
                  WHERE event.aggregate_type = 'review_response'),
                 (SELECT count(*) FROM tenant_audit_events
                  WHERE resource_type = 'review_response'
                    AND action IN ('review_response.published', 'review_response.updated'))
               """,
               [review_id]
             )
  end

  test "partner response authority is derived from the assigned place and organization" do
    fixture = published_review_fixture!()
    unrelated = partner_access!(fixture, operate_place?: false)

    assert {:error, :place_not_found} =
             Reviews.put_partner_response(
               unrelated.scope,
               fixture.submission.review.id,
               %{
                 "body" => "Não deveria responder por este estabelecimento.",
                 "idempotency_key" => "unrelated-partner-response-#{uuid7()}"
               }
             )
  end

  test "partner responses require a published review and valid public inputs" do
    fixture =
      RedemptionsFixtures.create!(alternate_validation_place: true)
      |> pending_review_from_redemption_fixture!()

    %{scope: partner_scope} = partner_access!(fixture)

    assert {:error, :review_not_responseable} =
             Reviews.put_partner_response(partner_scope, fixture.submission.review.id, %{
               "body" => "Avaliação ainda não foi publicada.",
               "idempotency_key" => "pending-review-response-#{uuid7()}"
             })

    assert {:error, :review_not_found} =
             Reviews.put_partner_response(partner_scope, "not-a-uuid", %{
               "body" => "Review inválido.",
               "idempotency_key" => "invalid-review-response"
             })

    assert {:error, %Ecto.Changeset{}} =
             Reviews.put_partner_response(partner_scope, fixture.submission.review.id, %{})

    assert {:error, :partner_access_required} =
             Reviews.put_partner_response(nil, fixture.submission.review.id, %{})
  end

  defp published_review_fixture! do
    fixture =
      RedemptionsFixtures.create!(alternate_validation_place: true)
      |> pending_review_from_redemption_fixture!()

    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _published} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-for-response-#{uuid7()}"
             })

    fixture
  end

  defp pending_review_from_redemption_fixture!(fixture) do
    assert {:ok, redemption} = Clubeira.Redemptions.confirm(fixture.scope, fixture.request)

    assert {:ok, submission} =
             Reviews.submit_verified(fixture.scope, %{
               place_id: fixture.ids.place,
               source_redemption_id: redemption.id,
               rating: 5,
               title: "Experiência verificada",
               body: "O benefício foi entregue como anunciado.",
               idempotency_key: "response-review-fixture-#{uuid7()}"
             })

    Map.merge(fixture, %{redemption: redemption, submission: submission})
  end

  defp partner_access!(fixture, options \\ []) do
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization, trade_name: "Parceiro da avaliação")

    operated_place_id =
      if Keyword.get(options, :operate_place?, true) do
        fixture.ids.place
      else
        fixture.ids.other_place
      end

    Factory.insert(:place_operator,
      place: Repo.get!(Place, operated_place_id),
      organization: organization
    )

    assert {:ok, _access} =
             Directory.grant_partner_access(admin_scope, operated_place_id, %{
               "email" => partner.email,
               "idempotency_key" => "grant-response-partner-#{uuid7()}"
             })

    %{
      organization: organization,
      scope:
        Scope.new!(fixture.ids.polo,
          actor_user_id: partner.id,
          request_id: uuid7()
        )
    }
  end

  defp scoped_query!(fixture, sql, parameters) do
    assert {:ok, result} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               {:ok, repo.query!(sql, Enum.map(parameters, &dump_uuid/1))}
             end)

    result
  end

  defp dump_uuid(value), do: Ecto.UUID.dump!(value)
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
