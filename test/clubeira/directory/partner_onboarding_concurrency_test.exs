defmodule Clubeira.Directory.PartnerOnboardingConcurrencyTest do
  use ExUnit.Case, async: false

  alias Clubeira.Directory
  alias Clubeira.Factory.Brazil
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Repo.RuntimeRole
  alias Clubeira.ReviewsFixtures

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
