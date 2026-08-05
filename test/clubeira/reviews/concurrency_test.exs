defmodule Clubeira.Reviews.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    database = "clubeira_reviews_concurrency_#{suffix}"

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

  test "serializes competing submissions for the same member and place", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    base_attributes = %{
      place_id: fixture.ids.place,
      source_redemption_id: redemption.id,
      rating: 5,
      body: "Avaliação concorrente."
    }

    results =
      run_concurrently(repo, [
        fn ->
          Reviews.submit_verified(
            fixture.scope,
            Map.put(base_attributes, :idempotency_key, "review-concurrent-001")
          )
        end,
        fn ->
          Reviews.submit_verified(
            fixture.scope,
            Map.put(base_attributes, :idempotency_key, "review-concurrent-002")
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _submission}, &1)) == 1
    assert Enum.count(results, &match?({:error, :review_already_exists}, &1)) == 1

    assert %{rows: [[1, 1, 1, 1, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM reviews WHERE place_id = $1),
                 (SELECT count(*) FROM review_revisions),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'review.submitted'),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.submitted'),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic = 'reviews.submitted'),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.submit_verified')
               """,
               [fixture.ids.place]
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
          5_000 -> flunk("concurrent review worker did not become ready")
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
