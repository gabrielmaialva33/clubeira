defmodule ClubeiraWeb.BackofficePartnerAccessControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceStaffAssignment
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-acesso-do-parceiro"

  test "a polo admin grants one verified user access to an operated place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    response =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-access-grant-001")
      |> post(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
          "#{fixture.ids.place}/partner-accesses",
        %{"email" => partner.email}
      )
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => access_id,
               "organization_id" => organization_id,
               "place_id" => place_id,
               "role" => "partner_manager",
               "status" => "active",
               "user_id" => user_id
             }
           } = response

    assert {:ok, ^access_id} = Ecto.UUID.cast(access_id)
    assert organization_id == organization.id
    assert place_id == fixture.ids.place
    assert user_id == partner.id

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-access-grant-001")
      |> post(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
          "#{fixture.ids.place}/partner-accesses",
        %{"email" => partner.email}
      )
      |> json_response(201)

    assert replayed == response

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               events =
                 repo.all(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "partner_access" and
                         event.aggregate_id == ^access_id and
                         event.event_type == "partner_access.granted"
                   )
                 )

               audits =
                 repo.all(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_type == "partner_access" and
                         audit.resource_id == ^access_id and
                         audit.action == "partner_access.granted"
                   )
                 )

               assert [%DomainEvent{} = event] = events
               assert [%TenantEvent{}] = audits

               assert repo.get_by!(OutboxMessage, domain_event_id: event.id).topic ==
                        "partners.access.granted"

               key =
                 repo.get_by!(Key,
                   scope: "directory.grant_partner_access",
                   idempotency_key: "partner-access-grant-001"
                 )

               assert key.status == "completed"

               assert repo.aggregate(
                        from(membership in PoloMembership,
                          where:
                            membership.polo_id == ^fixture.ids.polo and
                              membership.user_id == ^partner.id and
                              membership.status == "active"
                        ),
                        :count
                      ) == 1

               {:ok, :verified}
             end)
  end

  test "a partner lists only the assigned places inside the routed polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.other_place),
      organization: Factory.insert(:organization)
    )

    conn
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", "partner-access-list-001")
    |> post(
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
        "#{fixture.ids.place}/partner-accesses",
      %{"email" => partner.email}
    )
    |> json_response(201)

    partner_token = authenticate!(partner.id)

    assert %{
             "data" => [
               %{
                 "place" => %{"id" => place_id},
                 "polo_place_id" => polo_place_id,
                 "profile" => nil,
                 "status" => "active"
               }
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "has_more" => false,
                 "limit" => 20,
                 "next_cursor" => nil
               }
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{partner_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places")
             |> json_response(200)

    assert place_id == fixture.ids.place
    assert polo_place_id == fixture.ids.polo_place

    for query <- ["limit=0", "limit=101", "limit=invalid", "after=not-a-cursor"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{partner_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places?limit=1")
           |> json_response(200)
           |> get_in(["meta", "page", "limit"]) == 1

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/polo-inexistente/partner/places")
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "a partner publishes the public profile only for an assigned place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.other_place),
      organization: Factory.insert(:organization)
    )

    Factory.insert(:place_category, key: "cafe", name: "Café")

    conn
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", "partner-profile-grant-001")
    |> post(
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
        "#{fixture.ids.place}/partner-accesses",
      %{"email" => partner.email}
    )
    |> json_response(201)

    partner_token = authenticate!(partner.id)

    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{partner_token}")
      |> put_req_header("idempotency-key", "partner-profile-update-001")
      |> put(
        "/api/v1/polos/#{fixture.polo_slug}/partner/places/#{fixture.ids.place}/profile",
        profile_request()
      )
      |> json_response(200)

    assert get_in(response, ["data", "place_id"]) == fixture.ids.place
    assert get_in(response, ["data", "profile", "revision"]) == 1

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> put_req_header("idempotency-key", "partner-profile-unassigned-001")
           |> put(
             "/api/v1/polos/#{fixture.polo_slug}/partner/places/" <>
               "#{fixture.ids.other_place}/profile",
             profile_request()
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    public_place =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)
      |> get_in(["data", "places"])
      |> Enum.find(&(&1["place_id"] == fixture.ids.place))

    assert get_in(public_place, ["profile", "contact"]) == %{
             "email" => "parceiro@cafe.example",
             "phone" => "+5588999990101"
           }
  end

  test "a polo admin revokes partner access idempotently and access stops immediately", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    grant =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-revocation-grant-001")
      |> post(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
          "#{fixture.ids.place}/partner-accesses",
        %{"email" => partner.email}
      )
      |> json_response(201)

    access_id = get_in(grant, ["data", "id"])
    partner_token = authenticate!(partner.id)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places")
           |> json_response(200)
           |> get_in(["meta", "count"]) == 1

    revocation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/partner-accesses/" <>
        "#{access_id}/revocations"

    revoke = fn conn ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-access-revocation-001")
      |> post(revocation_path, %{"reason" => "Responsável removido do estabelecimento"})
      |> json_response(200)
    end

    first = revoke.(conn)
    replayed = revoke.(conn)

    assert replayed == first

    rejected =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-access-revocation-terminal-001")
      |> post(revocation_path, %{"reason" => "Segunda tentativa após revogação"})
      |> json_response(409)

    assert rejected == %{
             "errors" => %{
               "code" => "partner_access_revoked",
               "detail" => "Conflict"
             }
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-access-revocation-terminal-001")
           |> post(revocation_path, %{"reason" => "Segunda tentativa após revogação"})
           |> json_response(409) == rejected

    assert %{
             "data" => %{
               "id" => ^access_id,
               "role" => "partner_manager",
               "status" => "revoked",
               "user_id" => user_id,
               "valid_until" => valid_until
             }
           } = first

    assert user_id == partner.id
    assert {:ok, _valid_until, 0} = DateTime.from_iso8601(valid_until)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places")
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "partner_access" and
                         event.aggregate_id == ^access_id and
                         event.event_type == "partner_access.revoked"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_type == "partner_access" and
                         audit.resource_id == ^access_id and
                         audit.action == "partner_access.revoked"
                   )
                 )

               assert event.aggregate_version == 2
               refute Map.has_key?(event.payload, "reason")
               assert audit.metadata["reason"] == "Responsável removido do estabelecimento"

               assert repo.get_by!(OutboxMessage, domain_event_id: event.id).topic ==
                        "partners.access.revoked"

               assert repo.get_by!(Key,
                        scope: "directory.revoke_partner_access",
                        idempotency_key: "partner-access-revocation-001"
                      ).status == "completed"

               assert repo.get_by!(Key,
                        scope: "directory.revoke_partner_access",
                        idempotency_key: "partner-access-revocation-terminal-001"
                      ).status == "failed"

               assert repo.aggregate(
                        from(audit in TenantEvent,
                          where:
                            audit.resource_type == "partner_access" and
                              audit.resource_id == ^access_id and
                              audit.action == "partner_access.revocation_rejected"
                        ),
                        :count
                      ) == 1

               assert repo.get_by!(OrganizationMembership,
                        organization_id: organization.id,
                        user_id: partner.id,
                        status: "active"
                      )

               assert repo.get_by!(PlaceStaffAssignment,
                        place_id: fixture.ids.place,
                        user_id: partner.id,
                        status: "active"
                      )

               {:ok, :verified}
             end)
  end

  test "revoking one polo preserves the same partner's access in another polo", %{conn: conn} do
    sobral = RedemptionsFixtures.create!()
    londrina = RedemptionsFixtures.create!()
    sobral_admin = ReviewsFixtures.grant_moderator!(sobral, role_key: "admin")
    londrina_admin = ReviewsFixtures.grant_moderator!(londrina, role_key: "admin")
    sobral_admin_token = authenticate!(sobral_admin.actor_user_id)
    londrina_admin_token = authenticate!(londrina_admin.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))

    for fixture <- [sobral, londrina] do
      Factory.insert(:place_operator,
        place: Repo.get!(Place, fixture.ids.place),
        organization: Factory.insert(:organization)
      )
    end

    grant = fn conn, fixture, token, key ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", key)
      |> post(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
          "#{fixture.ids.place}/partner-accesses",
        %{"email" => partner.email}
      )
      |> json_response(201)
    end

    sobral_access_id =
      conn
      |> grant.(sobral, sobral_admin_token, "partner-multi-polo-sobral")
      |> get_in(["data", "id"])

    conn
    |> grant.(londrina, londrina_admin_token, "partner-multi-polo-londrina")

    partner_token = authenticate!(partner.id)

    for fixture <- [sobral, londrina] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{partner_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/partner/places")
             |> json_response(200)
             |> get_in(["meta", "count"]) == 1
    end

    cross_polo_path =
      "/api/v1/polos/#{londrina.polo_slug}/backoffice/partner-accesses/" <>
        "#{sobral_access_id}/revocations"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{londrina_admin_token}")
           |> put_req_header("idempotency-key", "partner-cross-polo-revocation")
           |> post(cross_polo_path, %{"reason" => "Tentativa em polo incorreto"})
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    sobral_revocation_path =
      "/api/v1/polos/#{sobral.polo_slug}/backoffice/partner-accesses/" <>
        "#{sobral_access_id}/revocations"

    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{sobral_admin_token}")
    |> put_req_header("idempotency-key", "partner-multi-polo-revocation")
    |> post(sobral_revocation_path, %{"reason" => "Encerramento apenas em Sobral"})
    |> json_response(200)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/#{sobral.polo_slug}/partner/places")
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{partner_token}")
           |> get("/api/v1/polos/#{londrina.polo_slug}/partner/places")
           |> json_response(200)
           |> get_in(["meta", "count"]) == 1
  end

  test "grant requires a polo admin and a verified target without partial writes", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    admin_token = authenticate!(admin_scope.actor_user_id)
    verified = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    unverified = Factory.insert(:user)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: Factory.insert(:organization)
    )

    path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
        "#{fixture.ids.place}/partner-accesses"

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "partner-access-moderator-denied")
           |> post(path, %{"email" => verified.email})
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    unverified_response =
      conn
      |> recycle()
      |> put_req_header("accept-language", "pt-BR")
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-access-unverified-denied")
      |> post(path, %{"email" => unverified.email})

    assert get_resp_header(unverified_response, "content-language") == ["pt-BR"]

    assert json_response(unverified_response, 422) == %{
             "errors" => %{
               "code" => "partner_user_not_found",
               "detail" => "Conteúdo não processável"
             }
           }

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               refute repo.exists?(
                        from(role in Clubeira.Polos.PoloRole,
                          where:
                            role.polo_id == ^fixture.ids.polo and role.key == "partner_manager"
                        )
                      )

               refute repo.exists?(
                        from(key in Key,
                          where:
                            key.scope == "directory.grant_partner_access" and
                              key.idempotency_key in ^[
                                "partner-access-moderator-denied",
                                "partner-access-unverified-denied"
                              ]
                        )
                      )

               {:ok, :verified}
             end)
  end

  test "partner access endpoints reject invalid boundary input and changed retries", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    other_partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: Factory.insert(:organization)
    )

    grant_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
        "#{fixture.ids.place}/partner-accesses"

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> post(grant_path, %{"email" => partner.email})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-invalid-email-001")
           |> post(grant_path, %{"email" => "email-invalido"})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-invalid-place-001")
           |> post(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/invalido/partner-accesses",
             %{"email" => partner.email}
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    grant =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "partner-boundary-grant-001")
      |> post(grant_path, %{"email" => partner.email})
      |> json_response(201)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-boundary-grant-001")
           |> post(grant_path, %{"email" => other_partner.email})
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    access_id = get_in(grant, ["data", "id"])

    revocation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/partner-accesses/" <>
        "#{access_id}/revocations"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> post(revocation_path, %{"reason" => "Responsável removido"})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-invalid-reason-001")
           |> post(revocation_path, %{"reason" => "x"})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-invalid-access-001")
           |> post(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/partner-accesses/invalido/revocations",
             %{"reason" => "Identificador inexistente"}
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "partner-revoke-moderator-denied")
           |> post(revocation_path, %{"reason" => "Sem autorização administrativa"})
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
  end

  test "grant preserves an existing polo membership instead of mixing access lifecycles", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    membership_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      INSERT INTO polo_memberships (id, polo_id, user_id, valid_during, status)
      VALUES (
        $1,
        $2,
        $3,
        tstzrange(statement_timestamp() - interval '1 hour', NULL, '[)'),
        'active'
      )
      """,
      [membership_id, fixture.ids.polo, partner.id]
    )

    path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
        "#{fixture.ids.place}/partner-accesses"

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "partner-existing-membership-001")
           |> post(path, %{"email" => partner.email})
           |> json_response(409) == %{
             "errors" => %{"code" => "partner_access_conflict", "detail" => "Conflict"}
           }

    refute Repo.get_by(OrganizationMembership,
             organization_id: organization.id,
             user_id: partner.id
           )

    refute Repo.get_by(PlaceStaffAssignment,
             place_id: fixture.ids.place,
             user_id: partner.id
           )

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               assert repo.get!(PoloMembership, membership_id).status == "active"

               refute repo.get_by(Key,
                        scope: "directory.grant_partner_access",
                        idempotency_key: "partner-existing-membership-001"
                      )

               {:ok, :verified}
             end)
  end

  defp profile_request do
    %{
      "contact" => %{
        "email" => "PARCEIRO@CAFE.EXAMPLE",
        "phone" => "(88) 99999-0101"
      },
      "category_keys" => ["cafe"],
      "weekly_hours" => [
        %{"weekday" => 1, "opens_at" => "08:00", "closes_at" => "18:00"}
      ],
      "special_hours" => []
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
