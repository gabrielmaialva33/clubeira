defmodule Clubeira.Redemptions.ConfirmTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "confirms one unit and records the complete transactional trail" do
    fixture = RedemptionsFixtures.create!()

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    assert redemption.polo_id == fixture.ids.polo
    assert redemption.entitlement_allocation_id == fixture.ids.entitlement_allocation
    assert redemption.polo_place_id == fixture.ids.polo_place
    assert redemption.units == 1

    assert %{rows: [[0, 1, 1, 1, 1, 1, "completed"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 allocation.available_units,
                 (SELECT count(*) FROM redemption_attempts WHERE decision = 'accepted'),
                 (SELECT count(*) FROM redemptions),
                 (SELECT count(*) FROM redemption_events WHERE event_type = 'confirmed'),
                 (SELECT count(*) FROM domain_events WHERE event_type = 'redemption.confirmed'),
                 (SELECT count(*) FROM outbox_messages WHERE topic = 'redemptions.confirmed'),
                 idempotency.status
               FROM entitlement_allocations AS allocation
               JOIN tenant_idempotency_keys AS idempotency
                 ON idempotency.resource_id = $2
               WHERE allocation.id = $1
               """,
               [fixture.ids.entitlement_allocation, redemption.id]
             )

    assert %{rows: [["initial_grant", 1], ["consumption", -1]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT entry_kind, delta_units
             FROM entitlement_ledger_entries
             ORDER BY inserted_at, entry_kind DESC
             """)

    assert %{rows: [[1]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT count(*)
             FROM tenant_audit_events
             WHERE action = 'redemption.confirmed'
             """)
  end

  test "replays the completed response without consuming or emitting twice" do
    fixture = RedemptionsFixtures.create!()

    assert {:ok, first} = Redemptions.confirm(fixture.scope, fixture.request)
    assert {:ok, replayed} = Redemptions.confirm(fixture.scope, fixture.request)
    assert replayed.id == first.id

    assert %{rows: [[1, 1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*) FROM redemption_attempts),
               (SELECT count(*) FROM redemptions),
               (SELECT count(*) FROM domain_events),
               (SELECT count(*) FROM outbox_messages)
             """)
  end

  test "scopes the idempotency key to the authenticated actor" do
    fixture = RedemptionsFixtures.create!()
    other_user_id = Ecto.UUID.generate(version: 7)

    RedemptionsFixtures.insert_user!(
      other_user_id,
      "other-#{other_user_id}@example.test"
    )

    other_scope =
      Scope.new!(fixture.ids.polo,
        actor_user_id: other_user_id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    other_request =
      RedemptionsFixtures.request(fixture, %{
        idempotency_key: fixture.request.idempotency_key
      })

    assert {:ok, _redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    assert {:error, :actor_not_entitled} = Redemptions.confirm(other_scope, other_request)
  end

  test "rejects reuse of an idempotency key with a different request" do
    fixture = RedemptionsFixtures.create!()
    conflicting = Map.put(fixture.request, :request_nonce, "different-request-nonce")

    assert {:ok, _redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    assert {:error, :idempotency_conflict} = Redemptions.confirm(fixture.scope, conflicting)

    assert %{rows: [[1, 1]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*) FROM redemption_attempts),
               (SELECT count(*) FROM redemptions)
             """)
  end

  test "treats the same nonce under another key as a replay attack" do
    fixture = RedemptionsFixtures.create!()

    replay_request =
      RedemptionsFixtures.request(fixture, %{
        request_nonce: fixture.request.request_nonce
      })

    assert {:ok, _redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    assert {:error, :nonce_replayed} = Redemptions.confirm(fixture.scope, replay_request)

    assert %{rows: [[1, 1, 2, 2, 2]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*) FROM redemption_attempts),
               (SELECT count(*) FROM redemptions),
               (SELECT count(*) FROM domain_events),
               (SELECT count(*) FROM outbox_messages),
               (SELECT count(*) FROM tenant_audit_events)
             """)
  end

  test "records an exhausted attempt without creating a second redemption" do
    fixture = RedemptionsFixtures.create!()
    exhausted_request = RedemptionsFixtures.request(fixture, %{})

    assert {:ok, _redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert {:error, :entitlement_exhausted} =
             Redemptions.confirm(fixture.scope, exhausted_request)

    assert {:error, :entitlement_exhausted} =
             Redemptions.confirm(fixture.scope, exhausted_request)

    assert %{rows: [[2, 1, 2, 2, 2, "failed"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM redemption_attempts),
                 (SELECT count(*) FROM redemptions),
                 (SELECT count(*) FROM domain_events),
                 (SELECT count(*) FROM outbox_messages),
                 (SELECT count(*) FROM tenant_audit_events),
                 idempotency.status
               FROM tenant_idempotency_keys AS idempotency
               WHERE idempotency.idempotency_key = $1
               """,
               [exhausted_request.idempotency_key]
             )
  end

  test "derives the member from scope and denies another authenticated user" do
    fixture = RedemptionsFixtures.create!()
    other_user_id = Ecto.UUID.generate(version: 7)
    other_user_raw = Ecto.UUID.dump!(other_user_id)

    RedemptionsFixtures.insert_user!(other_user_id, "other-#{other_user_id}@example.test")

    other_scope =
      Scope.new!(fixture.ids.polo,
        actor_user_id: other_user_id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:error, :actor_not_entitled} =
             Redemptions.confirm(other_scope, fixture.request)

    assert %{rows: [["denied", ^other_user_raw]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT decision, requesting_user_id
             FROM redemption_attempts
             """)
  end

  test "supports a shared allocation across places in its configured scope" do
    fixture = RedemptionsFixtures.create!(allocation_kind: "shared_scope")

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    assert redemption.polo_place_id == fixture.ids.polo_place

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT available_units
               FROM entitlement_allocations
               WHERE id = $1
               """,
               [fixture.ids.entitlement_allocation]
             )
  end

  test "enforces the versioned authorized-device policy" do
    denied_fixture = RedemptionsFixtures.create!(device_policy: "authorized_devices")

    assert {:error, :device_not_authorized} =
             Redemptions.confirm(denied_fixture.scope, denied_fixture.request)

    allowed_fixture =
      RedemptionsFixtures.create!(
        device_policy: "authorized_devices",
        authorize_device: true
      )

    assert {:ok, _redemption} =
             Redemptions.confirm(allowed_fixture.scope, allowed_fixture.request)
  end

  test "rejects a device installation owned by another authenticated user" do
    fixture = RedemptionsFixtures.create!()
    other_fixture = RedemptionsFixtures.create!()

    request =
      RedemptionsFixtures.request(fixture, %{
        device_installation_id: other_fixture.ids.device
      })

    assert {:error, :device_not_authorized} = Redemptions.confirm(fixture.scope, request)
  end

  test "evaluates redemption time at the current statement inside an outer transaction" do
    fixture = RedemptionsFixtures.create!()
    %{rows: [[before_confirmation]]} = Repo.query!("SELECT statement_timestamp()")

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    refute DateTime.before?(redemption.redeemed_at, before_confirmation)
  end

  test "denies a published offer during a persisted blackout" do
    fixture = RedemptionsFixtures.create!(blackout: true)

    assert {:error, :offer_blackout} = Redemptions.confirm(fixture.scope, fixture.request)

    assert %{rows: [[1, 0, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM redemption_attempts WHERE decision = 'denied'),
                 (SELECT count(*) FROM redemptions),
                 (SELECT available_units FROM entitlement_allocations WHERE id = $1)
               """,
               [fixture.ids.entitlement_allocation]
             )
  end

  test "outbox RLS exposes only messages from the active polo" do
    first_fixture = RedemptionsFixtures.create!()
    second_fixture = RedemptionsFixtures.create!()

    assert {:ok, _redemption} = Redemptions.confirm(first_fixture.scope, first_fixture.request)
    assert {:ok, _redemption} = Redemptions.confirm(second_fixture.scope, second_fixture.request)

    assert Repo.all(OutboxMessage) == []

    assert {:ok, [first_message]} =
             Repo.transact_in_polo(first_fixture.scope, fn ->
               {:ok, Repo.all(OutboxMessage)}
             end)

    assert {:ok, [second_message]} =
             Repo.transact_in_polo(second_fixture.scope, fn ->
               {:ok, Repo.all(OutboxMessage)}
             end)

    assert first_message.payload["polo_id"] == first_fixture.ids.polo
    assert second_message.payload["polo_id"] == second_fixture.ids.polo
  end

  test "requires an authenticated actor and validates command input before writing" do
    fixture = RedemptionsFixtures.create!()
    anonymous_scope = Scope.new!(fixture.ids.polo)

    assert {:error, :actor_required} = Redemptions.confirm(anonymous_scope, fixture.request)
    assert {:error, changeset} = Redemptions.confirm(fixture.scope, %{})
    assert errors_on(changeset).entitlement_allocation_id == ["can't be blank"]

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM redemption_attempts"
             )
  end
end
