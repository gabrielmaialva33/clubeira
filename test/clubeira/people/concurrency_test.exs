defmodule Clubeira.People.ConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Factory
  alias Clubeira.People
  alias Clubeira.People.Person
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    database = "clubeira_people_concurrency_#{suffix}"
    restricted_role = "clubeira_people_runtime_#{suffix}"

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
      |> Keyword.put(:pool_size, 4)
      |> then(&start_supervised!({Repo, &1}))

    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )

    Repo.put_dynamic_repo(repo)
    Repo.query!("CREATE ROLE #{restricted_role} NOLOGIN NOSUPERUSER NOBYPASSRLS")
    Repo.query!("GRANT USAGE ON SCHEMA public TO #{restricted_role}")

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{restricted_role}"
    )

    {:ok, repo: repo, restricted_role: restricted_role}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok
  end

  test "concurrent first PUTs converge on one self profile and one audit event", %{
    repo: repo,
    restricted_role: restricted_role
  } do
    user = Factory.insert(:user, email: "concurrent-profile@example.test")
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    attributes = %{
      "display_name" => "Perfil Concorrente",
      "cpf" => "52998224725",
      "phone" => "11999999999"
    }

    results =
      run_concurrently(repo, restricted_role, [
        fn -> People.put_self_profile(scope, attributes) end,
        fn -> People.put_self_profile(scope, attributes) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second
    assert Repo.aggregate(Person, :count) == 1

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.action == "person.self_profile.created"
             ),
             :count
           ) == 1
  end

  defp run_concurrently(repo, restricted_role, operations) do
    caller = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          run_concurrent_operation(repo, restricted_role, operation, caller)
        end)
      end)

    ready_processes =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, process} -> process
        after
          5_000 -> flunk("concurrent profile worker did not become ready")
        end
      end)

    Enum.each(ready_processes, &send(&1, :run))
    Task.await_many(tasks, 15_000)
  end

  defp run_concurrent_operation(repo, restricted_role, operation, caller) do
    Repo.put_dynamic_repo(repo)
    send(caller, {:ready, self()})

    receive do
      :run -> Repo.checkout(fn -> run_as_role(restricted_role, operation) end)
    end
  end

  defp run_as_role(restricted_role, operation) do
    Repo.query!("SET ROLE #{restricted_role}")

    try do
      operation.()
    after
      Repo.query!("RESET ROLE")
    end
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
