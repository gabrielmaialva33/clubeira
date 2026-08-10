defmodule ClubeiraWeb.Backoffice.PlaceProfileControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-administracao-forte"

  test "a polo admin publishes a complete place profile in the public directory", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "place-profile-api-001")
      |> put(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
        profile_request()
      )
      |> json_response(200)

    assert %{
             "data" => %{
               "place_id" => place_id,
               "polo_place_id" => polo_place_id,
               "profile" => profile
             }
           } = response

    assert place_id == fixture.ids.place
    assert polo_place_id == fixture.ids.polo_place

    assert profile == %{
             "revision" => 1,
             "contact" => %{
               "email" => "reservas@bistro.example",
               "phone" => "+5588999990101"
             },
             "categories" => [
               %{"key" => "cafe", "name" => "Café"},
               %{"key" => "restaurant", "name" => "Restaurante"}
             ],
             "weekly_hours" => [
               %{
                 "weekday" => 1,
                 "opens_at" => "11:30:00",
                 "closes_at" => "15:00:00",
                 "closes_next_day" => false
               },
               %{
                 "weekday" => 1,
                 "opens_at" => "18:00:00",
                 "closes_at" => "23:00:00",
                 "closes_next_day" => false
               }
             ],
             "special_hours" => [
               %{"date" => "2026-12-25", "kind" => "closed", "windows" => []}
             ]
           }

    public_place =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)
      |> get_in(["data", "places"])
      |> Enum.find(&(&1["place_id"] == fixture.ids.place))

    assert public_place["profile"] == profile
  end

  test "a replace advances the revision while replaying an older key returns its original response",
       %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    cafe = Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    first = put_profile(conn, fixture, token, "place-profile-revision-001", profile_request())

    replacement = %{
      "contact" => %{
        "email" => "contato@noturno.example",
        "phone" => "+55 88 98888-0202"
      },
      "category_keys" => ["restaurant"],
      "weekly_hours" => [
        %{"weekday" => 5, "opens_at" => "18:00", "closes_at" => "02:00"}
      ],
      "special_hours" => [
        %{
          "date" => "2026-12-31",
          "kind" => "custom",
          "windows" => [%{"opens_at" => "20:00", "closes_at" => "03:00"}]
        }
      ]
    }

    second =
      conn
      |> recycle()
      |> put_profile(fixture, token, "place-profile-revision-002", replacement)

    assert get_in(first, ["data", "profile", "revision"]) == 1

    assert %{
             "revision" => 2,
             "contact" => %{
               "email" => "contato@noturno.example",
               "phone" => "+5588988880202"
             },
             "categories" => [%{"key" => "restaurant"}],
             "weekly_hours" => [
               %{
                 "weekday" => 5,
                 "opens_at" => "18:00:00",
                 "closes_at" => "02:00:00",
                 "closes_next_day" => true
               }
             ],
             "special_hours" => [
               %{
                 "date" => "2026-12-31",
                 "kind" => "custom",
                 "windows" => [
                   %{
                     "opens_at" => "20:00:00",
                     "closes_at" => "03:00:00",
                     "closes_next_day" => true
                   }
                 ]
               }
             ]
           } = get_in(second, ["data", "profile"])

    cafe
    |> Ecto.Changeset.change(status: "retired")
    |> Repo.update!()

    replayed =
      conn
      |> recycle()
      |> put_profile(fixture, token, "place-profile-revision-001", profile_request())

    assert replayed == first

    public_profile =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)
      |> get_in(["data", "places", Access.at(0), "profile"])

    assert public_profile == get_in(second, ["data", "profile"])
  end

  test "publishing records one versioned event, outbox envelope and audit without contact data",
       %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    response =
      put_profile(conn, fixture, token, "place-profile-observability-001", profile_request())

    profile_id =
      Repo.transact_in_polo(admin_scope, fn repo ->
        event =
          repo.one!(
            from(event in DomainEvent,
              where:
                event.aggregate_type == "polo_place_profile" and
                  event.event_type == "place_profile.published"
            )
          )

        audit =
          repo.one!(
            from(audit in TenantEvent,
              where:
                audit.resource_type == "polo_place_profile" and
                  audit.action == "place_profile.published"
            )
          )

        outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

        key =
          repo.one!(
            from(key in Key,
              where:
                key.scope == "directory.publish_place_profile" and
                  key.idempotency_key == "place-profile-observability-001"
            )
          )

        assert event.aggregate_version == 1
        assert event.aggregate_id == audit.resource_id
        assert event.aggregate_id == key.resource_id
        assert key.response_status == 200
        assert outbox.topic == "places.profiles.published"
        assert outbox.message_key == event.aggregate_id

        sensitive = inspect([event.payload, event.metadata, audit.metadata, outbox.payload])
        refute sensitive =~ "reservas@bistro.example"
        refute sensitive =~ "+5588999990101"

        {:ok, event.aggregate_id}
      end)
      |> then(fn {:ok, profile_id} -> profile_id end)

    assert get_in(response, ["data", "profile", "revision"]) == 1
    assert is_binary(profile_id)
  end

  test "an unknown category rejects the whole replace without reserving idempotency", %{
    conn: conn
  } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    first = put_profile(conn, fixture, token, "place-profile-valid-001", profile_request())
    invalid = put_in(profile_request(), ["category_keys"], ["category-that-does-not-exist"])

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "place-profile-invalid-category")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
             invalid
           )
           |> json_response(422) == %{
             "errors" => %{
               "code" => "invalid_categories",
               "detail" => "Unprocessable Content"
             }
           }

    assert {:ok, 0} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.aggregate(
                  from(key in Key,
                    where: key.idempotency_key == "place-profile-invalid-category"
                  ),
                  :count
                )}
             end)

    public_profile =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)
      |> get_in(["data", "places", Access.at(0), "profile"])

    assert public_profile == get_in(first, ["data", "profile"])
  end

  test "weekly windows cannot overlap across the Sunday-to-Monday boundary", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    overlapping =
      put_in(profile_request(), ["weekly_hours"], [
        %{"weekday" => 7, "opens_at" => "22:00", "closes_at" => "02:00"},
        %{"weekday" => 1, "opens_at" => "01:00", "closes_at" => "04:00"}
      ])

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "place-profile-overlapping-week")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
             overlapping
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert conn
           |> recycle()
           |> get("/api/v1/polos/#{fixture.polo_slug}/places")
           |> json_response(200)
           |> get_in(["data", "places", Access.at(0), "profile"]) == nil
  end

  test "an overnight special window cannot overlap the following date", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    overlapping =
      put_in(profile_request(), ["special_hours"], [
        %{
          "date" => "2026-12-31",
          "kind" => "custom",
          "windows" => [%{"opens_at" => "20:00", "closes_at" => "03:00"}]
        },
        %{"date" => "2027-01-01", "kind" => "closed"}
      ])

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "place-profile-overlapping-special")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
             overlapping
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert conn
           |> recycle()
           |> get("/api/v1/polos/#{fixture.polo_slug}/places")
           |> json_response(200)
           |> get_in(["data", "places", Access.at(0), "profile"]) == nil
  end

  test "reusing an idempotency key for another profile conflicts without mutation", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    first = put_profile(conn, fixture, token, "place-profile-conflict-001", profile_request())
    changed = put_in(profile_request(), ["contact", "email"], "outro@example.test")

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "place-profile-conflict-001")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
             changed
           )
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    public_profile =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)
      |> get_in(["data", "places", Access.at(0), "profile"])

    assert public_profile == get_in(first, ["data", "profile"])
  end

  test "invalid contact and schedule input is rejected before any profile is written", %{
    conn: conn
  } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    invalid_requests = [
      put_in(profile_request(), ["contact", "email"], "sem-arroba"),
      put_in(profile_request(), ["contact", "phone"], "+1 212 555 0100"),
      put_in(profile_request(), ["contact", "phone"], "ligue (88) 99999-0101"),
      put_in(profile_request(), ["weekly_hours"], []),
      put_in(profile_request(), ["special_hours"], false),
      put_in(profile_request(), ["special_hours"], [
        %{
          "date" => "2026-12-25",
          "kind" => "closed",
          "windows" => [%{"opens_at" => "09:00", "closes_at" => "12:00"}]
        }
      ])
    ]

    invalid_requests
    |> Enum.with_index(1)
    |> Enum.each(fn {request, index} ->
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "place-profile-invalid-#{index}")
             |> put(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
               request
             )
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end)

    assert conn
           |> recycle()
           |> get("/api/v1/polos/#{fixture.polo_slug}/places")
           |> json_response(200)
           |> get_in(["data", "places", Access.at(0), "profile"]) == nil
  end

  test "only an admin membership in the routed polo can publish the profile", %{conn: conn} do
    authorized_polo = ReviewsFixtures.pending_review!()
    other_polo = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized_polo)
    token = authenticate!(moderator_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    for {fixture, key} <- [
          {authorized_polo, "place-profile-moderator-forbidden"},
          {other_polo, "place-profile-cross-polo-forbidden"}
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", key)
             |> put(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
               profile_request()
             )
             |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
    end
  end

  test "an admin cannot use a place id from another polo", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    other_polo = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    Factory.insert(:place_category, key: "cafe", name: "Café")
    Factory.insert(:place_category, key: "restaurant", name: "Restaurante")

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "place-profile-cross-polo-place")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{other_polo.ids.place}/profile",
             profile_request()
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  defp profile_request do
    %{
      "contact" => %{
        "email" => " RESERVAS@BISTRO.EXAMPLE ",
        "phone" => "(88) 99999-0101"
      },
      "category_keys" => ["restaurant", "cafe"],
      "weekly_hours" => [
        %{"weekday" => 1, "opens_at" => "11:30", "closes_at" => "15:00"},
        %{"weekday" => 1, "opens_at" => "18:00", "closes_at" => "23:00"}
      ],
      "special_hours" => [
        %{"date" => "2026-12-25", "kind" => "closed"}
      ]
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp put_profile(conn, fixture, token, idempotency_key, request) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> put(
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/profile",
      request
    )
    |> json_response(200)
  end
end
