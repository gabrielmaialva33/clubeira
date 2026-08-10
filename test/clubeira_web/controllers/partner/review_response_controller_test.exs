defmodule ClubeiraWeb.Partner.ReviewResponseControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Directory
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-resposta-do-parceiro"

  test "an assigned partner publishes a response visible in the public review feed", %{conn: conn} do
    fixture = published_review!()
    partner = grant_partner!(fixture)
    partner_token = authenticate!(partner.id)
    review_id = fixture.submission.review.id
    path = "/api/v1/polos/#{fixture.polo_slug}/partner/reviews/#{review_id}/response"

    response =
      conn
      |> put_req_header("authorization", "Bearer #{partner_token}")
      |> put_req_header("idempotency-key", "partner-public-review-response")
      |> put(path, %{"body" => "Valeu pela visita! Esperamos receber você novamente."})
      |> json_response(200)

    assert %{
             "data" => %{
               "id" => response_id,
               "review_id" => ^review_id,
               "organization" => %{"id" => organization_id},
               "revision_number" => 1,
               "status" => "published"
             }
           } = response

    assert {:ok, ^response_id} = Ecto.UUID.cast(response_id)
    assert organization_id == partner.organization_id

    assert %{
             "data" => [
               %{
                 "id" => ^review_id,
                 "response" => %{
                   "id" => ^response_id,
                   "organization" => %{"id" => ^organization_id},
                   "body" => "Valeu pela visita! Esperamos receber você novamente."
                 }
               }
             ]
           } =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews")
             |> json_response(200)
  end

  defp published_review! do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert {:ok, submission} =
             Reviews.submit_verified(fixture.scope, %{
               place_id: fixture.ids.place,
               source_redemption_id: redemption.id,
               rating: 5,
               body: "Atendimento excelente e benefício aplicado corretamente.",
               idempotency_key: "partner-response-http-review"
             })

    moderator = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _published} =
             Reviews.moderate(moderator, %{
               review_id: submission.review.id,
               action: "publish",
               reason: "Avaliação verificada e adequada.",
               idempotency_key: "partner-response-http-publish"
             })

    Map.merge(fixture, %{redemption: redemption, submission: submission})
  end

  defp grant_partner!(fixture) do
    admin = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization, trade_name: "Parceiro HTTP")

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, _access} =
             Directory.grant_partner_access(admin, fixture.ids.place, %{
               "email" => partner.email,
               "idempotency_key" => "partner-response-http-access"
             })

    %{id: partner.id, organization_id: organization.id}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
