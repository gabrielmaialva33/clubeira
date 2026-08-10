defmodule Clubeira.Redemptions.ValidationPointConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "concurrent retries provision one validation point and replay its credential metadata", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_point_counts(fixture)
    secret_sha256 = validation_secret_sha256()

    request = %{
      name: "Caixa concorrente",
      secret_sha256: secret_sha256,
      expires_at: DateTime.add(fixture.now, 90, :day),
      idempotency_key: "validation-point-concurrent-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Redemptions.provision_validation_point(scope, fixture.ids.place, request)
               end,
               fn ->
                 Redemptions.provision_validation_point(scope, fixture.ids.place, request)
               end
             ])

    assert first["id"] == second["id"]
    assert get_in(first, ["credential", "id"]) == get_in(second, ["credential", "id"])

    assert count_deltas(before, validation_point_counts(fixture)) == %{
             audits: 1,
             credentials: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1,
             points: 1
           }
  end

  test "concurrent distinct requests for one credential digest commit one stable point", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_point_counts(fixture)
    secret_sha256 = validation_secret_sha256()
    expires_at = DateTime.add(fixture.now, 90, :day)

    results =
      run_concurrently(repo, [
        fn ->
          Redemptions.provision_validation_point(scope, fixture.ids.place, %{
            name: "Caixa concorrente A",
            secret_sha256: secret_sha256,
            expires_at: expires_at,
            idempotency_key: "validation-point-concurrent-first"
          })
        end,
        fn ->
          Redemptions.provision_validation_point(scope, fixture.ids.place, %{
            name: "Caixa concorrente B",
            secret_sha256: secret_sha256,
            expires_at: expires_at,
            idempotency_key: "validation-point-concurrent-second"
          })
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :credential_already_registered}, &1)) == 1

    assert count_deltas(before, validation_point_counts(fixture)) == %{
             audits: 2,
             credentials: 1,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1,
             points: 1
           }
  end

  test "concurrent retries suspend one validation point and replay the committed transition", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_point_lifecycle_counts(fixture)

    request = %{
      action: "suspend",
      reason: "Isolamento concorrente do terminal",
      idempotency_key: "validation-point-concurrent-suspension-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Redemptions.transition_validation_point(
                   scope,
                   fixture.ids.validation_point,
                   request
                 )
               end,
               fn ->
                 Redemptions.transition_validation_point(
                   scope,
                   fixture.ids.validation_point,
                   request
                 )
               end
             ])

    assert first == second
    assert first["status"] == "suspended"
    assert first["revision"] == 2

    assert count_deltas(before, validation_point_lifecycle_counts(fixture)) == %{
             audits: 1,
             credentials: 0,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1
           }
  end

  test "concurrent credential rotation and point retirement leave no active credential", %{
    repo: repo
  } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_point_credential_lifecycle_counts(fixture)

    [rotation_result, {:ok, retirement}] =
      run_concurrently(repo, [
        fn ->
          Redemptions.rotate_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{
              secret_sha256: validation_secret_sha256(),
              expires_at: DateTime.add(fixture.now, 90, :day),
              idempotency_key: "validation-point-racing-credential-rotation"
            }
          )
        end,
        fn ->
          Redemptions.transition_validation_point(scope, fixture.ids.validation_point, %{
            action: "retire",
            reason: "Retirada definitiva durante troca de credencial",
            idempotency_key: "validation-point-racing-retirement"
          })
        end
      ])

    assert retirement["status"] == "retired"

    {expected_revision, expected_version, expected_delta} =
      case rotation_result do
        {:ok, rotation} ->
          assert get_in(rotation, ["credential", "version"]) == 2

          {3, 2,
           %{
             audits: 3,
             credentials: 1,
             domain_events: 3,
             idempotency_keys: 2,
             outbox_messages: 3
           }}

        {:error, :validation_point_not_found} ->
          {2, 1,
           %{
             audits: 2,
             credentials: 0,
             domain_events: 2,
             idempotency_keys: 1,
             outbox_messages: 2
           }}
      end

    assert count_deltas(before, validation_point_credential_lifecycle_counts(fixture)) ==
             expected_delta

    assert %{rows: [["retired", ^expected_revision, 0, ^expected_version, ^expected_version]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 point.status,
                 point.revision,
                 count(*) FILTER (WHERE credential.status = 'active'),
                 count(*) FILTER (WHERE credential.status = 'revoked'),
                 max(credential.version)
               FROM validation_points AS point
               JOIN validation_credentials AS credential
                 ON credential.polo_id = point.polo_id
                AND credential.validation_point_id = point.id
               WHERE point.id = $1
               GROUP BY point.status, point.revision
               """,
               [fixture.ids.validation_point]
             )
  end

  test "concurrent point retirement and credential revocation serialize terminal state", %{
    repo: repo
  } do
    current_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = validation_point_credential_lifecycle_counts(fixture)

    [{:ok, retirement}, revocation_result] =
      run_concurrently(repo, [
        fn ->
          Redemptions.transition_validation_point(scope, fixture.ids.validation_point, %{
            action: "retire",
            reason: "Encerramento definitivo concorrente",
            idempotency_key: "validation-point-racing-revocation-retirement"
          })
        end,
        fn ->
          Redemptions.revoke_validation_credential(
            scope,
            fixture.ids.validation_credential,
            %{idempotency_key: "validation-point-racing-explicit-revocation"}
          )
        end
      ])

    assert retirement["status"] == "retired"

    expected_audits =
      case revocation_result do
        {:ok, revocation} ->
          assert get_in(revocation, ["credential", "status"]) == "revoked"
          2

        {:error, :validation_credential_revoked} ->
          3
      end

    assert count_deltas(before, validation_point_credential_lifecycle_counts(fixture)) == %{
             audits: expected_audits,
             credentials: 0,
             domain_events: 2,
             idempotency_keys: 2,
             outbox_messages: 2
           }

    assert %{rows: [["retired", 2, "revoked", 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 point.status,
                 point.revision,
                 credential.status,
                 count(*) FILTER (WHERE credential.status = 'active') OVER ()
               FROM validation_points AS point
               JOIN validation_credentials AS credential
                 ON credential.polo_id = point.polo_id
                AND credential.validation_point_id = point.id
               WHERE point.id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  defp validation_point_counts(fixture) do
    %{rows: [[points, credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_points),
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_point.provisioned',
             'validation_point.provisioning_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'validation_point'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'redemptions.validation_points.provisioned'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'redemptions.provision_validation_point')
      """)

    %{
      points: points,
      credentials: credentials,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp validation_point_lifecycle_counts(fixture) do
    %{rows: [[credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_point.suspended',
             'validation_point.reactivated',
             'validation_point.retired',
             'validation_point.transition_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type IN (
             'validation_point.suspended',
             'validation_point.reactivated',
             'validation_point.retired'
           )),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN (
             'redemptions.validation_points.suspended',
             'redemptions.validation_points.reactivated',
             'redemptions.validation_points.retired'
           )),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'redemptions.transition_validation_point')
      """)

    %{
      credentials: credentials,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp validation_point_credential_lifecycle_counts(fixture) do
    %{rows: [[credentials, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM validation_credentials),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'validation_point.retired',
             'validation_credential.rotated',
             'validation_credential.revoked',
             'validation_credential.revocation_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type IN (
             'validation_point.retired',
             'validation_credential.rotated',
             'validation_credential.revoked'
           )),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN (
             'redemptions.validation_points.retired',
             'redemptions.validation_credentials.rotated',
             'redemptions.validation_credentials.revoked'
           )),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope IN (
             'redemptions.transition_validation_point',
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
