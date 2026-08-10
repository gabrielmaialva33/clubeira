defmodule Clubeira.Directory.PartnerConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.Factory.Brazil
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "concurrent retries of one onboarding return one committed partner", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = counts(fixture)
    request = onboarding_request("retry", "12.ABC.345/01DE-35", "partner-concurrent-retry")

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Directory.onboard_partner(scope, request) end,
               fn -> Directory.onboard_partner(scope, request) end
             ])

    assert first.organization.id == second.organization.id
    assert first.place.id == second.place.id
    assert first.participation.id == second.participation.id

    assert count_deltas(before, counts(fixture)) == %{
             addresses: 1,
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             identifiers: 1,
             operators: 1,
             organizations: 1,
             outbox_messages: 1,
             places: 1,
             polo_places: 1
           }
  end

  test "concurrent distinct requests for one CNPJ commit one partner and one stable conflict", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = counts(fixture)
    cnpj = Brazil.cnpj(73_001)

    results =
      run_concurrently(repo, [
        fn ->
          Directory.onboard_partner(
            scope,
            onboarding_request("first", cnpj, "partner-concurrent-first")
          )
        end,
        fn ->
          Directory.onboard_partner(
            scope,
            onboarding_request("second", cnpj, "partner-concurrent-second")
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :cnpj_already_registered}, &1)) == 1
    assert rejection_count(fixture) == 1

    assert count_deltas(before, counts(fixture)) == %{
             addresses: 1,
             audits: 1,
             domain_events: 1,
             idempotency_keys: 2,
             identifiers: 1,
             operators: 1,
             organizations: 1,
             outbox_messages: 1,
             places: 1,
             polo_places: 1
           }
  end

  test "concurrent distinct CNPJs for one place slug commit one partner and one stable conflict",
       %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Directory.onboard_partner(
            scope,
            onboarding_request("shared-slug", Brazil.cnpj(73_002), "partner-slug-first")
          )
        end,
        fn ->
          Directory.onboard_partner(
            scope,
            onboarding_request("shared-slug", Brazil.cnpj(73_003), "partner-slug-second")
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :place_slug_taken}, &1)) == 1
    assert rejection_count(fixture) == 1

    assert count_deltas(before, counts(fixture)) == %{
             addresses: 1,
             audits: 1,
             domain_events: 1,
             idempotency_keys: 2,
             identifiers: 1,
             operators: 1,
             organizations: 1,
             outbox_messages: 1,
             places: 1,
             polo_places: 1
           }
  end

  test "concurrent retries grant one complete partner access and replay its response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Clubeira.Directory.Place, fixture.ids.place),
      organization: organization
    )

    request = %{
      email: partner.email,
      idempotency_key: "partner-access-concurrent-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Directory.grant_partner_access(scope, fixture.ids.place, request) end,
               fn -> Directory.grant_partner_access(scope, fixture.ids.place, request) end
             ])

    assert first == second
    assert first["status"] == "active"

    assert partner_access_counts(fixture, partner.id) == %{
             active_memberships: 1,
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             organization_memberships: 1,
             outbox_messages: 1,
             staff_assignments: 1
           }
  end

  test "concurrent retries revoke one partner access without touching global affiliation", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Clubeira.Directory.Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, access} =
             Directory.grant_partner_access(scope, fixture.ids.place, %{
               email: partner.email,
               idempotency_key: "partner-access-before-concurrent-revocation"
             })

    request = %{
      reason: "Revogação concorrente do responsável",
      idempotency_key: "partner-access-concurrent-revocation"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Directory.revoke_partner_access(scope, access["id"], request) end,
               fn -> Directory.revoke_partner_access(scope, access["id"], request) end
             ])

    assert first == second
    assert first["status"] == "revoked"

    assert %{rows: [["revoked", false, 1, 1, 1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 pm.status,
                 pm.valid_during @> statement_timestamp(),
                 (SELECT count(*) FROM organization_memberships WHERE user_id = $2),
                 (SELECT count(*) FROM place_staff_assignments WHERE user_id = $2),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'partner_access.revoked' AND resource_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'partner_access.revoked' AND aggregate_id = $1),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'directory.revoke_partner_access'
                      AND idempotency_key = 'partner-access-concurrent-revocation')
               FROM polo_memberships pm
               WHERE pm.id = $1
               """,
               [access["id"], partner.id]
             )
  end

  defp onboarding_request(suffix, cnpj, idempotency_key) do
    %{
      organization: %{
        legal_name: "Parceiro Concorrente #{suffix} Ltda.",
        trade_name: "Parceiro Concorrente #{suffix}",
        cnpj: cnpj
      },
      place: %{
        name: "Parceiro Concorrente #{suffix}",
        slug: "parceiro-concorrente-#{suffix}",
        address: %{
          postal_code: "62010000",
          street: "Rua da Concorrência",
          number: "10",
          district: "Centro"
        }
      },
      idempotency_key: idempotency_key
    }
  end

  defp partner_access_counts(fixture, user_id) do
    %{
      rows: [
        [
          active_memberships,
          organization_memberships,
          staff_assignments,
          audits,
          events,
          outbox,
          idempotency_keys
        ]
      ]
    } =
      RedemptionsFixtures.scoped_query!(
        fixture,
        """
        SELECT
          (SELECT count(*) FROM polo_memberships
             WHERE user_id = $1 AND status = 'active'
               AND valid_during @> statement_timestamp()),
          (SELECT count(*) FROM organization_memberships
             WHERE user_id = $1 AND status = 'active'
               AND valid_during @> statement_timestamp()),
          (SELECT count(*) FROM place_staff_assignments
             WHERE user_id = $1 AND status = 'active'
               AND valid_during @> statement_timestamp()),
          (SELECT count(*) FROM tenant_audit_events
             WHERE action = 'partner_access.granted'),
          (SELECT count(*) FROM domain_events
             WHERE event_type = 'partner_access.granted'),
          (SELECT count(*) FROM outbox_messages
             WHERE topic = 'partners.access.granted'),
          (SELECT count(*) FROM tenant_idempotency_keys
             WHERE scope = 'directory.grant_partner_access'
               AND idempotency_key = 'partner-access-concurrent-retry')
        """,
        [user_id]
      )

    %{
      active_memberships: active_memberships,
      organization_memberships: organization_memberships,
      staff_assignments: staff_assignments,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp counts(fixture) do
    %{rows: [[organizations, identifiers, addresses, places, operators]]} =
      Repo.query!("""
      SELECT
        (SELECT count(*) FROM organizations),
        (SELECT count(*) FROM organization_identifiers),
        (SELECT count(*) FROM addresses),
        (SELECT count(*) FROM places),
        (SELECT count(*) FROM place_operators)
      """)

    %{rows: [[polo_places, audits, domain_events, outbox_messages, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM polo_places),
        (SELECT count(*) FROM tenant_audit_events WHERE action = 'partner.onboarded'),
        (SELECT count(*) FROM domain_events WHERE event_type = 'partner.onboarded'),
        (SELECT count(*) FROM outbox_messages WHERE topic = 'partners.onboarded'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'directory.onboard_partner')
      """)

    %{
      organizations: organizations,
      identifiers: identifiers,
      addresses: addresses,
      places: places,
      operators: operators,
      polo_places: polo_places,
      audits: audits,
      domain_events: domain_events,
      outbox_messages: outbox_messages,
      idempotency_keys: idempotency_keys
    }
  end

  defp rejection_count(fixture) do
    %{rows: [[count]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT count(*)
      FROM tenant_audit_events
      WHERE action = 'partner.onboarding_rejected'
      """)

    count
  end
end
