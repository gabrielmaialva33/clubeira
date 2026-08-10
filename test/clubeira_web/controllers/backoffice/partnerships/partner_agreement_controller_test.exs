defmodule ClubeiraWeb.Backoffice.PartnerAgreementControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.BillingFixtures
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.Partnerships
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-convenios"

  test "a polo admin publishes and reads one complete atomic partner agreement", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.user.id)
    graph = agreement_graph!(fixture)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/partner-agreements"
    attributes = agreement_attributes(fixture, graph)

    assert conn
           |> put_req_header("authorization", "Bearer #{member_token}")
           |> put_req_header("idempotency-key", "member-cannot-publish-agreement")
           |> post(path, attributes)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    created =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "publish-complete-partner-agreement")
      |> post(path, attributes)

    assert %{
             "data" => %{
               "id" => agreement_id,
               "agreement_number" => agreement_number,
               "name" => "Convênio gastronômico anual",
               "status" => "active",
               "terms" => %{
                 "version" => 1,
                 "settlement_model" => "revenue_share",
                 "redemption_sla_seconds" => 45
               },
               "organization_ids" => organization_ids,
               "brand_ids" => brand_ids,
               "polo_ids" => [polo_id],
               "polo_place_ids" => polo_place_ids,
               "edition_ids" => edition_ids,
               "benefit_offer_version_ids" => offer_version_ids
             }
           } = json_response(created, 201)

    assert agreement_number == String.upcase(attributes["agreement_number"])
    assert organization_ids == [graph.organization.id]
    assert brand_ids == [graph.brand.id]
    assert polo_id == fixture.polo.id
    assert polo_place_ids == [fixture.polo_place.id]
    assert edition_ids == [graph.edition.id]
    assert offer_version_ids == [graph.benefit_offer_version_id]

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "publish-complete-partner-agreement")
           |> post(path, attributes)
           |> json_response(200) == json_response(created, 201)

    assert %{"data" => [%{"id" => ^agreement_id}], "page" => %{"has_more" => false}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?status=active")
             |> json_response(200)

    assert %{"data" => %{"id" => ^agreement_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "/#{agreement_id}")
             |> json_response(200)

    assert {:ok, %{rows: [[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               result =
                 repo.query!(
                   """
                   SELECT
                     (SELECT count(*) FROM partner_agreements WHERE id = $1),
                     (SELECT count(*) FROM partner_agreement_terms WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_organizations WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_brands WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_polos WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_polo_places WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_editions WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM partner_agreement_offer_versions WHERE partner_agreement_id = $1),
                     (SELECT count(*) FROM domain_events
                      WHERE aggregate_type = 'partner_agreement' AND aggregate_id = $1),
                     (SELECT count(*) FROM tenant_audit_events
                      WHERE resource_type = 'partner_agreement' AND resource_id = $1),
                     (SELECT count(*) FROM outbox_messages AS message
                      JOIN domain_events AS event ON event.id = message.domain_event_id
                      WHERE event.aggregate_type = 'partner_agreement' AND event.aggregate_id = $1)
                   """,
                   [Ecto.UUID.dump!(agreement_id)]
                 )

               {:ok, result}
             end)
  end

  test "agreement conflicts, invalid references and pagination fail with stable API errors", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    graph = agreement_graph!(fixture)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/partner-agreements"
    attributes = agreement_attributes(fixture, graph)

    first =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "publish-first-pagination-agreement")
      |> post(path, attributes)

    assert %{"data" => %{"id" => first_id}} = json_response(first, 201)

    assert %{"errors" => %{"code" => "agreement_number_taken"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "conflicting-agreement-number")
             |> post(path, attributes)
             |> json_response(409)

    assert %{"errors" => %{"code" => "organization_not_found"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "agreement-with-missing-organization")
             |> post(path, %{
               attributes
               | "agreement_number" => "MISSING-ORG-#{String.slice(uuid7(), -8, 8)}",
                 "organization_ids" => [uuid7()]
             })
             |> json_response(422)

    second_attributes = %{
      attributes
      | "agreement_number" => "SECOND-#{String.slice(uuid7(), -8, 8)}",
        "name" => "Segundo convênio para paginação",
        "brand_ids" => [],
        "edition_ids" => []
    }

    second =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "publish-second-pagination-agreement")
      |> post(path, second_attributes)

    assert %{"data" => %{"id" => second_id}} = json_response(second, 201)
    assert first_id != second_id

    assert %{
             "data" => [%{"id" => ^second_id}],
             "page" => %{"has_more" => true, "next_cursor" => cursor}
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^first_id}], "page" => %{"has_more" => false}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&after=#{URI.encode_www_form(cursor)}")
             |> json_response(200)

    assert %{"errors" => %{"detail" => "Bad Request"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=0")
             |> json_response(400)

    assert %{"errors" => %{"detail" => "Unprocessable Content"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?status=unknown")
             |> json_response(422)

    assert %{"errors" => %{"detail" => "Not Found"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "/not-a-uuid")
             |> json_response(404)
  end

  test "agreement reads fail closed for malformed scopes and preserve an empty page" do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")

    assert {:ok, %{agreements: [], page: %{has_more: false, next_cursor: nil}}} =
             Partnerships.list_agreements(admin_scope, %{})

    assert {:error, :partner_admin_required} =
             Partnerships.list_agreements(fixture.service_scope, %{})

    assert {:error, :partner_admin_required} = Partnerships.list_agreements(nil, %{})

    assert {:error, :partner_admin_required} =
             Partnerships.list_agreements(fixture.member_scope, %{})

    assert {:error, :partner_admin_required} =
             Partnerships.get_agreement(fixture.service_scope, uuid7())

    assert {:error, :partner_admin_required} = Partnerships.get_agreement(nil, uuid7())

    assert {:error, :partner_admin_required} =
             Partnerships.get_agreement(fixture.member_scope, uuid7())

    assert {:error, :partner_agreement_not_found} =
             Partnerships.get_agreement(admin_scope, uuid7())

    assert {:error, :invalid_pagination} =
             Partnerships.list_agreements(admin_scope, %{"limit" => 1})

    assert {:error, :invalid_pagination} =
             Partnerships.list_agreements(admin_scope, %{"after" => 1})
  end

  defp agreement_graph!(fixture) do
    now = DateTime.utc_now(:microsecond)
    organization = Factory.insert(:organization, trade_name: "Rede gastronômica")
    brand = Factory.insert(:brand)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.polo_place.place_id),
      organization: organization
    )

    Factory.insert(:brand_ownership,
      brand: brand,
      organization: organization,
      valid_during: Factory.tstz_range(DateTime.add(now, -3_600))
    )

    assert {:ok, edition} =
             Repo.transact_in_polo(fixture.service_scope, fn ->
               {:ok, Factory.insert(:edition, polo: fixture.polo)}
             end)

    benefit_offer_version_id =
      fixture.package_items |> hd() |> Map.fetch!(:benefit_offer_version_id)

    %{
      now: now,
      organization: organization,
      brand: brand,
      edition: edition,
      benefit_offer_version_id: benefit_offer_version_id
    }
  end

  defp polo_fixture(fixture) do
    %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope}
  end

  defp agreement_attributes(fixture, graph) do
    %{
      "agreement_number" => "CV-#{String.slice(fixture.polo.id, -8, 8)}",
      "name" => "Convênio gastronômico anual",
      "valid_from" => DateTime.to_iso8601(DateTime.add(graph.now, -60)),
      "valid_until" => DateTime.to_iso8601(DateTime.add(graph.now, 365 * 86_400)),
      "signed_at" => DateTime.to_iso8601(graph.now),
      "settlement_model" => "revenue_share",
      "redemption_sla_seconds" => 45,
      "organization_ids" => [graph.organization.id],
      "brand_ids" => [graph.brand.id],
      "polo_place_ids" => [fixture.polo_place.id],
      "edition_ids" => [graph.edition.id],
      "benefit_offer_version_ids" => [graph.benefit_offer_version_id]
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
