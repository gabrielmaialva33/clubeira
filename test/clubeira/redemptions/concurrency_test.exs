defmodule Clubeira.Redemptions.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    database = "clubeira_concurrency_#{suffix}"

    with_admin_connection(fn admin ->
      Postgrex.query!(admin, ~s|CREATE DATABASE "#{database}" TEMPLATE template0|, [])
    end)

    on_exit(fn ->
      with_admin_connection(fn admin ->
        Postgrex.query!(admin, ~s|DROP DATABASE "#{database}" WITH (FORCE)|, [])
      end)
    end)

    repo =
      Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 6)
      |> then(&start_supervised!({Repo, &1}))

    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )

    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok
  end

  test "serializes competing confirmations for the final entitlement unit", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    competing_request = RedemptionsFixtures.request(fixture, %{})

    results =
      run_concurrently(repo, [
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end,
        fn -> Redemptions.confirm(fixture.scope, competing_request) end
      ])

    assert Enum.count(results, &match?({:ok, _redemption}, &1)) == 1
    assert Enum.count(results, &match?({:error, :entitlement_exhausted}, &1)) == 1

    assert %{rows: [[0, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT available_units FROM entitlement_allocations WHERE id = $1),
                 (SELECT count(*) FROM redemptions WHERE polo_id = $2),
                 (SELECT count(*) FROM redemption_attempts WHERE polo_id = $2)
               """,
               [fixture.ids.entitlement_allocation, fixture.ids.polo]
             )
  end

  test "replays one committed result for concurrent retries of the same request", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()

    results =
      run_concurrently(repo, [
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end,
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id

    assert %{rows: [[1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM redemptions WHERE polo_id = $1),
                 (SELECT count(*) FROM redemption_attempts WHERE polo_id = $1),
                 (SELECT count(*) FROM tenant_idempotency_keys WHERE polo_id = $1)
               """,
               [fixture.ids.polo]
             )
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
          5_000 -> flunk("concurrent redemption worker did not become ready")
        end
      end)

    Enum.each(ready_processes, &send(&1, :run))
    Task.await_many(tasks, 15_000)
  end

  defp connection_options(database) do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options])
    |> Keyword.put(:database, database)
  end

  defp with_admin_connection(operation) do
    {:ok, admin} = Postgrex.start_link(connection_options("postgres"))

    try do
      operation.(admin)
    after
      GenServer.stop(admin)
    end
  end
end
