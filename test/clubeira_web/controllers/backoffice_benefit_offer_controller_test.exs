defmodule ClubeiraWeb.BackofficeBenefitOfferControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Idempotency.Key
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  @password "uma-senha-de-administracao-forte"

  test "a polo admin publishes a benefit v1 that is immediately visible in the catalog", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)

    response = publish(conn, fixture, token, "benefit-offer-publish-001", request)

    assert %{
             "data" => %{
               "offer" => %{
                 "id" => offer_id,
                 "code" => "cafe-cortesia",
                 "name" => "Café cortesia",
                 "benefit_kind" => "discount_percentage",
                 "status" => "active"
               },
               "version" => %{
                 "id" => offer_version_id,
                 "number" => 1,
                 "title" => "15% no café da manhã",
                 "description" => "Desconto no consumo do café da manhã.",
                 "terms" => "Um uso por ciclo, de segunda a sexta.",
                 "redemption_instructions" => "Apresente o voucher antes de pedir a conta.",
                 "benefit" => %{
                   "percentage" => "15.0000",
                   "amount" => nil,
                   "currency" => nil
                 },
                 "effective_during" => %{
                   "starts_at" => starts_at,
                   "ends_at" => nil
                 },
                 "status" => "published",
                 "published_at" => published_at
               },
               "place" => %{
                 "id" => place_id,
                 "polo_place_id" => polo_place_id
               }
             }
           } = response

    assert place_id == fixture.ids.place
    assert polo_place_id == fixture.ids.polo_place
    assert starts_at == get_in(request, ["version", "effective_during", "starts_at"])
    assert {:ok, _published_at, 0} = DateTime.from_iso8601(published_at)

    public_offer =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/catalog")
      |> json_response(200)
      |> get_in(["data", "offers"])
      |> Enum.find(&(&1["offer_id"] == offer_id))

    assert public_offer == %{
             "offer_id" => offer_id,
             "offer_version_id" => offer_version_id,
             "version" => 1,
             "code" => "cafe-cortesia",
             "name" => "Café cortesia",
             "title" => "15% no café da manhã",
             "description" => "Desconto no consumo do café da manhã.",
             "terms" => "Um uso por ciclo, de segunda a sexta.",
             "redemption_instructions" => "Apresente o voucher antes de pedir a conta.",
             "benefit" => %{
               "kind" => "discount_percentage",
               "percentage" => "15.0000",
               "amount" => nil,
               "currency" => nil
             },
             "effective_during" => %{"starts_at" => starts_at, "ends_at" => nil},
             "places" => [
               %{
                 "polo_place_id" => fixture.ids.polo_place,
                 "place_id" => fixture.ids.place,
                 "slug" => "place-#{short_suffix(fixture.ids.polo)}",
                 "name" => "Parceiro #{short_suffix(fixture.ids.polo)}"
               }
             ]
           }
  end

  test "a polo admin rediscovers a published benefit with its immutable version and place", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)

    published =
      publish(conn, fixture, token, "benefit-offer-inventory-publication", request)

    offer_id = get_in(published, ["data", "offer", "id"])
    version_id = get_in(published, ["data", "version", "id"])

    assert %{
             "data" => [
               %{
                 "id" => ^offer_id,
                 "code" => "cafe-cortesia",
                 "name" => "Café cortesia",
                 "benefit_kind" => "discount_percentage",
                 "status" => "active",
                 "recorded_at" => recorded_at,
                 "latest_version" => %{
                   "id" => ^version_id,
                   "version" => 1,
                   "title" => "15% no café da manhã",
                   "description" => "Desconto no consumo do café da manhã.",
                   "terms" => "Um uso por ciclo, de segunda a sexta.",
                   "redemption_instructions" => "Apresente o voucher antes de pedir a conta.",
                   "status" => "published",
                   "published_at" => published_at,
                   "effective_from" => effective_from,
                   "effective_until" => nil,
                   "benefit" => %{
                     "percentage" => "15.0000",
                     "amount" => nil,
                     "currency" => nil
                   },
                   "places" => [
                     %{
                       "polo_place_id" => polo_place_id,
                       "id" => place_id,
                       "name" => place_name,
                       "slug" => place_slug,
                       "status" => "active",
                       "participation_status" => "active"
                     }
                   ]
                 }
               }
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(benefit_offer_inventory_path(fixture) <> "?code=cafe-cortesia")
             |> json_response(200)

    for timestamp <- [recorded_at, published_at, effective_from] do
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)
    end

    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
    assert is_binary(place_name)
    assert is_binary(place_slug)
  end

  test "the benefit inventory paginates inside one polo and filters the latest place assignment",
       %{
         conn: conn
       } do
    fixture =
      RedemptionsFixtures.create!(offer_status: "retired", alternate_validation_place: true)

    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    published =
      publish(
        conn,
        fixture,
        token,
        "benefit-offer-inventory-pagination",
        offer_request(fixture)
      )

    published_id = get_in(published, ["data", "offer", "id"])
    inventory_path = benefit_offer_inventory_path(fixture)

    assert %{
             "data" => [%{"id" => ^published_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(inventory_path <> "?limit=1")
             |> json_response(200)

    assert is_binary(cursor)
    refute cursor =~ published_id

    assert %{
             "data" => [%{"id" => original_offer_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(inventory_path <> "?limit=1&after=#{cursor}")
             |> json_response(200)

    assert original_offer_id == fixture.ids.benefit_offer
    refute original_offer_id == other_polo.ids.benefit_offer

    assert %{"data" => [%{"id" => ^original_offer_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(inventory_path <> "?status=retired")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^original_offer_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(inventory_path <> "?place_id=#{fixture.ids.other_place}")
             |> json_response(200)
  end

  test "the benefit inventory enforces polo capability and validates every filter", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    inventory_path = benefit_offer_inventory_path(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> get(inventory_path)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(benefit_offer_inventory_path(other_polo))
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert %{"data" => []} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(inventory_path <> "?place_id=#{other_polo.ids.place}")
             |> json_response(200)

    for query <- ["after=not-a-cursor", "limit=0", "limit=101"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(inventory_path <> "?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    for query <- ["code=x", "status=unknown", "place_id=not-a-uuid"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(inventory_path <> "?#{query}")
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end
  end

  test "publishing a duplicate code returns a stable conflict without partial catalog data", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)

    _published = publish(conn, fixture, token, "benefit-offer-code-original", request)

    for _retry <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "benefit-offer-code-duplicate")
             |> post(benefit_offers_path(fixture), request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "benefit_offer_code_conflict",
                 "detail" => "Conflict"
               }
             }
    end

    assert %{rows: [[1, 1, 1, 1, 409]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM benefit_offers WHERE code = 'cafe-cortesia'),
                 (
                   SELECT count(*)
                   FROM benefit_offer_versions AS version
                   JOIN benefit_offers AS offer
                     ON offer.id = version.benefit_offer_id
                    AND offer.polo_id = version.polo_id
                   WHERE offer.code = 'cafe-cortesia'
                 ),
                 (
                   SELECT count(*)
                   FROM tenant_audit_events
                   WHERE action = 'benefit_offer.publication_rejected'
                 ),
                 (
                   SELECT count(*)
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key = 'benefit-offer-code-duplicate'
                 ),
                 (
                   SELECT response_status
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key = 'benefit-offer-code-duplicate'
                 )
               """
             )
  end

  test "an exact retry replays the original response and one atomic observable publication", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)
    key = "benefit-offer-observable-replay"

    first = publish(conn, fixture, token, key, request)
    replayed = publish(recycle(conn), fixture, token, key, request)

    assert replayed == first

    offer_id = get_in(first, ["data", "offer", "id"])
    version_id = get_in(first, ["data", "version", "id"])

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_id == ^offer_id and
                         event.event_type == "benefit_offer.published"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^offer_id and
                         audit.action == "benefit_offer.published"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               idempotency =
                 repo.one!(
                   from(idempotency in Key,
                     where:
                       idempotency.scope == "catalog.publish_benefit_offer" and
                         idempotency.idempotency_key == ^key
                   )
                 )

               assert event.aggregate_version == 1
               assert event.aggregate_id == audit.resource_id
               assert event.aggregate_id == idempotency.resource_id
               assert event.payload["benefit_offer_version_id"] == version_id
               assert idempotency.resource_type == "benefit_offer"
               assert idempotency.response_status == 201
               assert idempotency.response_body == first["data"]
               assert outbox.topic == "catalog.benefit_offers.published"
               assert outbox.message_key == offer_id

               assert repo.aggregate(
                        from(event in DomainEvent, where: event.aggregate_id == ^offer_id),
                        :count
                      ) == 1

               assert repo.aggregate(
                        from(audit in TenantEvent, where: audit.resource_id == ^offer_id),
                        :count
                      ) == 1

               {:ok, :verified}
             end)
  end

  test "reusing an idempotency key for different content conflicts without mutation", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)
    key = "benefit-offer-idempotency-conflict"

    first = publish(conn, fixture, token, key, request)
    changed = put_in(request, ["offer", "name"], "Outro nome")

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", key)
           |> post(benefit_offers_path(fixture), changed)
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    offer_id = get_in(first, ["data", "offer", "id"])

    assert %{rows: [[^offer_id, "Café cortesia", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT offer.id::text, offer.name, count(version.id)
               FROM benefit_offers AS offer
               JOIN benefit_offer_versions AS version
                 ON version.benefit_offer_id = offer.id
                AND version.polo_id = offer.polo_id
               WHERE offer.code = 'cafe-cortesia'
               GROUP BY offer.id, offer.name
               """
             )
  end

  test "only an admin in the routed polo can publish for an active local participation", %{
    conn: conn
  } do
    authorized = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    inactive = RedemptionsFixtures.create!(place_status: "retired")
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)
    admin_scope = ReviewsFixtures.grant_moderator!(authorized, role_key: "admin")
    inactive_admin_scope = ReviewsFixtures.grant_moderator!(inactive, role_key: "admin")
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    admin_token = authenticate!(admin_scope.actor_user_id)
    inactive_admin_token = authenticate!(inactive_admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "benefit-offer-moderator-forbidden")
           |> post(benefit_offers_path(authorized), offer_request(authorized))
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "benefit-offer-other-polo-forbidden")
           |> post(benefit_offers_path(other_polo), offer_request(other_polo))
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_path =
      "/api/v1/polos/#{authorized.polo_slug}/backoffice/places/#{other_polo.ids.place}/benefit-offers"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "benefit-offer-cross-polo-place")
           |> post(cross_polo_path, offer_request(authorized))
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{inactive_admin_token}")
           |> put_req_header("idempotency-key", "benefit-offer-inactive-place")
           |> post(benefit_offers_path(inactive), offer_request(inactive))
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    for fixture <- [authorized, other_polo, inactive] do
      assert %{rows: [[0, 0]]} =
               RedemptionsFixtures.scoped_query!(
                 fixture,
                 """
                 SELECT
                   (SELECT count(*) FROM benefit_offers WHERE code = 'cafe-cortesia'),
                   (
                     SELECT count(*)
                     FROM tenant_idempotency_keys
                     WHERE scope = 'catalog.publish_benefit_offer'
                   )
                 """
               )
    end
  end

  test "a monetary discount is normalized and published with exact decimal value", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    request =
      fixture
      |> offer_request()
      |> put_in(["offer", "code"], "credito-dez-reais")
      |> put_in(["offer", "name"], "Crédito de dez reais")
      |> put_in(["offer", "benefit_kind"], "discount_amount")
      |> update_in(["version"], fn version ->
        version
        |> Map.delete("percentage_value")
        |> Map.put("amount_value", "10.5")
        |> Map.put("currency", " brl ")
      end)

    response = publish(conn, fixture, token, "benefit-offer-amount-001", request)

    assert %{
             "amount" => "10.50",
             "currency" => "BRL",
             "percentage" => nil
           } = get_in(response, ["data", "version", "benefit"])

    offer_id = get_in(response, ["data", "offer", "id"])

    assert %{
             "benefit" => %{
               "kind" => "discount_amount",
               "amount" => "10.50",
               "currency" => "BRL",
               "percentage" => nil
             }
           } =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/catalog")
             |> json_response(200)
             |> get_in(["data", "offers"])
             |> Enum.find(&(&1["offer_id"] == offer_id))
  end

  test "invalid benefit contracts and effective periods are rejected before reserving a key", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    request = offer_request(fixture)
    starts_at = get_in(request, ["version", "effective_during", "starts_at"])

    invalid_requests = [
      put_in(request, ["offer", "code"], "Código Inválido"),
      put_in(request, ["offer", "benefit_kind"], "surpresa"),
      update_in(request, ["version"], &Map.delete(&1, "percentage_value")),
      put_in(request, ["version", "percentage_value"], "100.0001"),
      put_in(request, ["version", "percentage_value"], "15.00001"),
      put_in(request, ["version", "amount_value"], "10.00"),
      amount_request(request, "10.001", "BRL"),
      amount_request(request, "10.00", "123"),
      request
      |> put_in(["offer", "benefit_kind"], "complimentary_item")
      |> put_in(["version", "percentage_value"], "10"),
      put_in(request, ["version", "effective_during", "ends_at"], starts_at),
      put_in(request, ["version", "effective_during", "starts_at"], "agora"),
      put_in(request, ["version", "terms"], " ")
    ]

    invalid_requests
    |> Enum.with_index(1)
    |> Enum.each(fn {invalid, index} ->
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "benefit-offer-invalid-#{index}")
             |> post(benefit_offers_path(fixture), invalid)
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> post(benefit_offers_path(fixture), request)
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }

    assert %{rows: [[0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM benefit_offers WHERE code = 'cafe-cortesia'),
                 (
                   SELECT count(*)
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key LIKE 'benefit-offer-invalid-%'
                 )
               """
             )
  end

  test "a conflicting ambient tenant scope returns a stable conflict instead of crashing", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    ambient_scope =
      Scope.new!(other_polo.ids.polo, actor_user_id: admin_scope.actor_user_id)

    assert {:ok, response_conn} =
             Repo.transact_in_polo(ambient_scope, fn _repo ->
               response_conn =
                 conn
                 |> recycle()
                 |> put_req_header("authorization", "Bearer #{token}")
                 |> put_req_header("idempotency-key", "benefit-offer-tenant-mismatch")
                 |> post(benefit_offers_path(fixture), offer_request(fixture))

               {:ok, response_conn}
             end)

    assert json_response(response_conn, 409) == %{
             "errors" => %{
               "code" => "tenant_scope_mismatch",
               "detail" => "Conflict"
             }
           }
  end

  defp offer_request(fixture) do
    %{
      "offer" => %{
        "code" => "cafe-cortesia",
        "name" => "Café cortesia",
        "benefit_kind" => "discount_percentage"
      },
      "version" => %{
        "title" => "15% no café da manhã",
        "description" => "Desconto no consumo do café da manhã.",
        "terms" => "Um uso por ciclo, de segunda a sexta.",
        "redemption_instructions" => "Apresente o voucher antes de pedir a conta.",
        "percentage_value" => "15.0000",
        "effective_during" => %{
          "starts_at" => fixture.now |> DateTime.add(-60) |> DateTime.to_iso8601(),
          "ends_at" => nil
        }
      }
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp amount_request(request, amount, currency) do
    request
    |> put_in(["offer", "benefit_kind"], "discount_amount")
    |> update_in(["version"], fn version ->
      version
      |> Map.delete("percentage_value")
      |> Map.put("amount_value", amount)
      |> Map.put("currency", currency)
    end)
  end

  defp benefit_offers_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/benefit-offers"
  end

  defp benefit_offer_inventory_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/benefit-offers"
  end

  defp publish(conn, fixture, token, idempotency_key, request) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(benefit_offers_path(fixture), request)
    |> json_response(201)
  end

  defp short_suffix(id), do: id |> String.replace("-", "") |> String.slice(-12, 12)
end
