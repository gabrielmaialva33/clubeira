defmodule Clubeira.Directory.PartnerOnboardingConcurrencyTest do
  use ExUnit.Case, async: false

  alias Clubeira.Catalog
  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.Factory.Brazil
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Repo.RuntimeRole
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)
    database = "clubeira_directory_concurrency_#{suffix}"
    restricted_role = "clubeira_directory_runtime_#{suffix}"

    with_admin_connection("postgres", fn admin ->
      Postgrex.query!(admin, ~s|CREATE DATABASE "#{database}" TEMPLATE template0|, [])
    end)

    on_exit(fn ->
      with_admin_connection("postgres", fn admin ->
        Postgrex.query!(admin, ~s|DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)|, [])
        Postgrex.query!(admin, "DROP ROLE IF EXISTS #{restricted_role}", [])
      end)
    end)

    migrate_database!(database)
    create_restricted_role!(database, restricted_role)

    repo = start_runtime_repo!(database, restricted_role)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
    end)

    Repo.put_dynamic_repo(repo)
    assert :ok = RuntimeRole.validate_repo!(Repo)

    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok
  end

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

  test "concurrent retries publish one place profile and replay the committed response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    category = Factory.insert(:place_category)

    request =
      profile_request(category.key, "profile-concurrent-retry", %{
        email: "retry@parceiro.example",
        phone: "+5588999990101",
        weekday: 2
      })

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Directory.publish_place_profile(scope, fixture.ids.place, request) end,
               fn -> Directory.publish_place_profile(scope, fixture.ids.place, request) end
             ])

    assert first == second
    assert get_in(first, ["profile", "revision"]) == 1

    assert profile_counts(fixture) == %{
             audits: 1,
             categories: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1,
             periods: 1,
             profiles: 1
           }
  end

  test "concurrent profile replacements serialize complete revisions without lost updates", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    morning = Factory.insert(:place_category)
    evening = Factory.insert(:place_category)

    first_request =
      profile_request(morning.key, "profile-concurrent-first", %{
        email: "manha@parceiro.example",
        phone: "+5588999990102",
        weekday: 3
      })

    second_request =
      profile_request(evening.key, "profile-concurrent-second", %{
        email: "noite@parceiro.example",
        phone: "+5588999990103",
        weekday: 4
      })

    assert [{:ok, _first}, {:ok, _second}] =
             results =
             run_concurrently(repo, [
               fn ->
                 Directory.publish_place_profile(scope, fixture.ids.place, first_request)
               end,
               fn ->
                 Directory.publish_place_profile(scope, fixture.ids.place, second_request)
               end
             ])

    assert results
           |> Enum.map(fn {:ok, result} -> get_in(result, ["profile", "revision"]) end)
           |> Enum.sort() == [1, 2]

    {:ok, directory} = Directory.fetch_public(fixture.polo_slug)
    public_place = Enum.find(directory.places, &(&1.place_id == fixture.ids.place))

    revision_two =
      Enum.find_value(results, fn
        {:ok, %{"profile" => %{"revision" => 2} = profile}} -> profile
        _other -> nil
      end)

    assert public_place.profile == revision_two

    assert profile_counts(fixture) == %{
             audits: 2,
             categories: 1,
             domain_events: 2,
             idempotency_keys: 2,
             outbox_messages: 2,
             periods: 1,
             profiles: 1
           }
  end

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

  test "concurrent retries publish one benefit offer and replay the committed response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = benefit_offer_counts(fixture)
    request = benefit_offer_request("retry", "benefit-offer-concurrent-retry", fixture)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Catalog.publish_benefit_offer(scope, fixture.ids.place, request) end,
               fn -> Catalog.publish_benefit_offer(scope, fixture.ids.place, request) end
             ])

    assert first == second

    assert count_deltas(before, benefit_offer_counts(fixture)) == %{
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             offer_places: 1,
             offers: 1,
             outbox_messages: 1,
             versions: 1
           }
  end

  test "concurrent distinct keys for one benefit code commit one offer and one stable conflict",
       %{
         repo: repo
       } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = benefit_offer_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Catalog.publish_benefit_offer(
            scope,
            fixture.ids.place,
            benefit_offer_request("shared", "benefit-offer-concurrent-first", fixture)
          )
        end,
        fn ->
          Catalog.publish_benefit_offer(
            scope,
            fixture.ids.place,
            benefit_offer_request("shared", "benefit-offer-concurrent-second", fixture)
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :offer_code_taken}, &1)) == 1

    assert count_deltas(before, benefit_offer_counts(fixture)) == %{
             audits: 2,
             domain_events: 1,
             idempotency_keys: 2,
             offer_places: 1,
             offers: 1,
             outbox_messages: 1,
             versions: 1
           }
  end

  test "concurrent retries publish one complete product offering and replay its response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_counts(fixture)
    request = product_offering_request("product-offering-concurrent-retry", fixture)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Subscriptions.publish_product_offering(scope, request) end,
               fn -> Subscriptions.publish_product_offering(scope, request) end
             ])

    assert first == second

    assert count_deltas(before, product_offering_counts(fixture)) == %{
             access_product_versions: 1,
             access_products: 1,
             audits: 1,
             benefit_package_items: 1,
             benefit_package_versions: 1,
             benefit_packages: 1,
             domain_events: 1,
             entitlement_scope_places: 1,
             entitlement_scopes: 1,
             idempotency_keys: 1,
             offering_prices: 1,
             outbox_messages: 1,
             package_assignments: 1,
             product_offering_versions: 1,
             product_offerings: 1
           }
  end

  test "concurrent distinct keys for one product code commit one graph and one conflict", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Subscriptions.publish_product_offering(
            scope,
            product_offering_request("product-offering-concurrent-first", fixture)
          )
        end,
        fn ->
          Subscriptions.publish_product_offering(
            scope,
            product_offering_request("product-offering-concurrent-second", fixture)
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :product_offering_code_taken}, &1)) == 1

    assert count_deltas(before, product_offering_counts(fixture)) == %{
             access_product_versions: 1,
             access_products: 1,
             audits: 2,
             benefit_package_items: 1,
             benefit_package_versions: 1,
             benefit_packages: 1,
             domain_events: 1,
             entitlement_scope_places: 1,
             entitlement_scopes: 1,
             idempotency_keys: 2,
             offering_prices: 1,
             outbox_messages: 1,
             package_assignments: 1,
             product_offering_versions: 1,
             product_offerings: 1
           }
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

  defp profile_request(category_key, idempotency_key, attributes) do
    %{
      contact: %{email: attributes.email, phone: attributes.phone},
      category_keys: [category_key],
      weekly_hours: [
        %{weekday: attributes.weekday, opens_at: "09:00", closes_at: "18:00"}
      ],
      special_hours: [],
      idempotency_key: idempotency_key
    }
  end

  defp benefit_offer_request(suffix, idempotency_key, fixture) do
    %{
      offer: %{
        code: "beneficio-concorrente-#{suffix}",
        name: "Benefício concorrente #{suffix}",
        benefit_kind: "complimentary_item"
      },
      version: %{
        title: "Cortesia concorrente #{suffix}",
        description: "Benefício publicado sob concorrência real.",
        terms: "Um uso por ciclo.",
        redemption_instructions: "Apresente o voucher no caixa.",
        effective_during: %{
          starts_at: DateTime.add(fixture.now, -60),
          ends_at: nil
        }
      },
      idempotency_key: idempotency_key
    }
  end

  defp product_offering_request(idempotency_key, fixture) do
    %{
      offering: %{
        code: "produto-concorrente",
        name: "Produto concorrente",
        description: "Configuração comercial publicada sob concorrência real.",
        cycle: %{policy: "calendar", interval_unit: "month", interval_count: 1},
        effective_during: %{
          starts_at: DateTime.add(fixture.now, -60),
          ends_at: nil
        }
      },
      price: %{currency: "BRL", amount: "49.90"},
      benefits: [
        %{
          benefit_offer_version_id: fixture.ids.benefit_offer_version,
          allowance_per_cycle: 1,
          consumption_unit: "per_place"
        }
      ],
      idempotency_key: idempotency_key
    }
  end

  defp benefit_offer_counts(fixture) do
    %{rows: [[offers, versions, offer_places, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM benefit_offers),
        (SELECT count(*) FROM benefit_offer_versions),
        (SELECT count(*) FROM benefit_offer_version_places),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'benefit_offer.published',
             'benefit_offer.publication_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'benefit_offer'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'catalog.benefit_offers.published'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'catalog.publish_benefit_offer')
      """)

    %{
      offers: offers,
      versions: versions,
      offer_places: offer_places,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp product_offering_counts(fixture) do
    %{
      rows: [
        [
          access_products,
          access_product_versions,
          product_offerings,
          product_offering_versions,
          offering_prices,
          benefit_packages,
          benefit_package_versions,
          entitlement_scopes,
          entitlement_scope_places,
          benefit_package_items,
          package_assignments,
          audits,
          events,
          outbox,
          idempotency_keys
        ]
      ]
    } =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM access_products),
        (SELECT count(*) FROM access_product_versions),
        (SELECT count(*) FROM product_offerings),
        (SELECT count(*) FROM product_offering_versions),
        (SELECT count(*) FROM offering_prices),
        (SELECT count(*) FROM benefit_packages),
        (SELECT count(*) FROM benefit_package_versions),
        (SELECT count(*) FROM entitlement_scopes),
        (SELECT count(*) FROM entitlement_scope_places),
        (SELECT count(*) FROM benefit_package_items),
        (SELECT count(*) FROM product_offering_package_assignments),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'product_offering.published',
             'product_offering.publication_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'product_offering'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'subscriptions.product_offerings.published'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'subscriptions.publish_product_offering')
      """)

    %{
      access_products: access_products,
      access_product_versions: access_product_versions,
      product_offerings: product_offerings,
      product_offering_versions: product_offering_versions,
      offering_prices: offering_prices,
      benefit_packages: benefit_packages,
      benefit_package_versions: benefit_package_versions,
      entitlement_scopes: entitlement_scopes,
      entitlement_scope_places: entitlement_scope_places,
      benefit_package_items: benefit_package_items,
      package_assignments: package_assignments,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp profile_counts(fixture) do
    %{rows: [[profiles, categories, periods, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM polo_place_profiles),
        (SELECT count(*) FROM polo_place_profile_categories),
        (SELECT count(*) FROM polo_place_opening_periods),
        (SELECT count(*) FROM tenant_audit_events
           WHERE resource_type = 'polo_place_profile'),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'polo_place_profile'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN ('places.profiles.published', 'places.profiles.updated')),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'directory.publish_place_profile')
      """)

    %{
      profiles: profiles,
      categories: categories,
      periods: periods,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
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

  defp count_deltas(before, after_counts) do
    Map.new(before, fn {key, count} -> {key, Map.fetch!(after_counts, key) - count} end)
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

  defp validation_secret_sha256 do
    :crypto.strong_rand_bytes(32)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp run_concurrently(repo, operations) do
    caller = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(caller, {:ready, self()})

          receive do
            :run -> operation.()
          end
        end)
      end)

    ready_processes =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, process} -> process
        after
          5_000 -> flunk("concurrent partner onboarding worker did not become ready")
        end
      end)

    Enum.each(ready_processes, &send(&1, :run))
    Task.await_many(tasks, 15_000)
  end

  defp migrate_database!(database) do
    config =
      Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    {:ok, migrator_repo} = Repo.start_link(config)

    try do
      Ecto.Migrator.run(
        Repo,
        Ecto.Migrator.migrations_path(Repo),
        :up,
        all: true,
        dynamic_repo: migrator_repo,
        log: false
      )
    after
      Supervisor.stop(migrator_repo)
    end
  end

  defp create_restricted_role!(database, role) do
    with_admin_connection(database, fn admin ->
      Postgrex.query!(
        admin,
        "CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
        []
      )

      Postgrex.query!(admin, "GRANT USAGE ON SCHEMA public TO #{role}", [])

      Postgrex.query!(
        admin,
        "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}",
        []
      )

      Postgrex.query!(admin, "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO #{role}", [])
    end)
  end

  defp start_runtime_repo!(database, role) do
    Repo.config()
    |> Keyword.put(:database, database)
    |> Keyword.put(:name, nil)
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 6)
    |> Keyword.put(:after_connect, {Postgrex, :query!, ["SET ROLE #{role}", []]})
    |> then(&start_supervised!({Repo, &1}))
  end

  defp connection_options(database) do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options])
    |> Keyword.put(:database, database)
  end

  defp with_admin_connection(database, operation) do
    {:ok, admin} = Postgrex.start_link(connection_options(database))

    try do
      operation.(admin)
    after
      GenServer.stop(admin)
    end
  end
end
