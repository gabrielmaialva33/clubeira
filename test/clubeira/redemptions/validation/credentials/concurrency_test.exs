defmodule Clubeira.Redemptions.ValidationCredentialConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "concurrent retries rotate one validation credential and replay its metadata", %{
    repo: repo
  } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_credential_rotation_counts(fixture)

    request = %{
      secret_sha256: validation_secret_sha256(),
      expires_at: DateTime.add(fixture.now, 90, :day),
      idempotency_key: "validation-credential-concurrent-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Redemptions.rotate_validation_credential(
                   scope,
                   fixture.ids.validation_credential,
                   request
                 )
               end,
               fn ->
                 Redemptions.rotate_validation_credential(
                   scope,
                   fixture.ids.validation_credential,
                   request
                 )
               end
             ])

    assert first == second
    assert get_in(first, ["credential", "version"]) == 2

    assert count_deltas(before, validation_credential_rotation_counts(fixture)) == %{
             audits: 1,
             credentials: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1
           }
  end

  test "concurrent distinct rotations of one credential commit one winner and one stale conflict",
       %{
         repo: repo
       } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_credential_rotation_counts(fixture)
    expires_at = DateTime.add(fixture.now, 90, :day)

    results =
      run_concurrently(repo, [
        fn ->
          Redemptions.rotate_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{
              secret_sha256: validation_secret_sha256(),
              expires_at: expires_at,
              idempotency_key: "validation-credential-concurrent-first"
            }
          )
        end,
        fn ->
          Redemptions.rotate_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{
              secret_sha256: validation_secret_sha256(),
              expires_at: expires_at,
              idempotency_key: "validation-credential-concurrent-second"
            }
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :validation_credential_stale}, &1)) == 1

    assert count_deltas(before, validation_credential_rotation_counts(fixture)) == %{
             audits: 2,
             credentials: 1,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1
           }

    assert %{rows: [[1, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 count(*) FILTER (WHERE status = 'revoked'),
                 count(*) FILTER (WHERE status = 'active'),
                 max(version)
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "concurrent retries revoke one validation credential and replay its metadata", %{
    repo: repo
  } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_credential_revocation_counts(fixture)
    request = %{idempotency_key: "validation-credential-concurrent-revocation-retry"}

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Redemptions.revoke_validation_credential(
                   scope,
                   fixture.ids.validation_credential,
                   request
                 )
               end,
               fn ->
                 Redemptions.revoke_validation_credential(
                   scope,
                   fixture.ids.validation_credential,
                   request
                 )
               end
             ])

    assert first == second
    assert get_in(first, ["credential", "status"]) == "revoked"

    assert count_deltas(before, validation_credential_revocation_counts(fixture)) == %{
             audits: 1,
             credentials: 0,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1
           }
  end

  test "concurrent rotation and revocation of one credential commit one lifecycle winner", %{
    repo: repo
  } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_credential_lifecycle_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Redemptions.rotate_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{
              secret_sha256: validation_secret_sha256(),
              expires_at: DateTime.add(fixture.now, 90, :day),
              idempotency_key: "validation-credential-racing-rotation"
            }
          )
        end,
        fn ->
          Redemptions.revoke_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{idempotency_key: "validation-credential-racing-revocation"}
          )
        end
      ])

    credential_delta =
      case results do
        [{:ok, rotation}, {:error, :validation_credential_stale}] ->
          assert get_in(rotation, ["credential", "status"]) == "active"
          1

        [{:error, :validation_credential_revoked}, {:ok, revocation}] ->
          assert get_in(revocation, ["credential", "status"]) == "revoked"
          0
      end

    assert count_deltas(before, validation_credential_lifecycle_counts(fixture)) == %{
             audits: 2,
             credentials: credential_delta,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1
           }

    expected_rows =
      if credential_delta == 1,
        do: [[1, 1, 2]],
        else: [[1, 0, 1]]

    state =
      RedemptionsFixtures.scoped_query!(
        fixture,
        """
        SELECT
          count(*) FILTER (WHERE status = 'revoked'),
          count(*) FILTER (WHERE status = 'active'),
          max(version)
        FROM validation_credentials
        WHERE validation_point_id = $1
        """,
        [fixture.ids.validation_point]
      )

    assert state.rows == expected_rows
  end

  defp validation_credential_rotation_counts(fixture) do
    %{rows: [[credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_credential.rotated',
             'validation_credential.rotation_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type = 'validation_credential.rotated'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'redemptions.validation_credentials.rotated'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'redemptions.rotate_validation_credential')
      """)

    %{
      credentials: credentials,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp validation_credential_revocation_counts(fixture) do
    %{rows: [[credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_credential.revoked',
             'validation_credential.revocation_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type = 'validation_credential.revoked'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'redemptions.validation_credentials.revoked'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'redemptions.revoke_validation_credential')
      """)

    %{
      credentials: credentials,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp validation_credential_lifecycle_counts(fixture) do
    %{rows: [[credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_credential.rotated',
             'validation_credential.rotation_rejected',
             'validation_credential.revoked',
             'validation_credential.revocation_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type IN (
             'validation_credential.rotated',
             'validation_credential.revoked'
           )),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN (
             'redemptions.validation_credentials.rotated',
             'redemptions.validation_credentials.revoked'
           )),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope IN (
             'redemptions.rotate_validation_credential',
             'redemptions.revoke_validation_credential'
           ))
      """)

    %{
      credentials: credentials,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp validation_secret_sha256 do
    :crypto.strong_rand_bytes(32)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
