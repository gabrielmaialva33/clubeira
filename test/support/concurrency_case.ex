defmodule Clubeira.ConcurrencyCase do
  @moduledoc """
  Runs real concurrency tests against an isolated PostgreSQL database.

  Each test module receives its own migrated database and a restricted runtime
  role, so concurrent commands exercise the same pool, RLS and constraints used
  in production without sharing sandbox ownership.
  """

  use ExUnit.CaseTemplate

  alias Clubeira.Repo
  alias Clubeira.Repo.RuntimeRole

  using do
    quote do
      import Clubeira.ConcurrencyCase,
        only: [count_deltas: 2, run_concurrently: 2]
    end
  end

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)
    database = "clubeira_concurrency_#{suffix}"
    restricted_role = "clubeira_runtime_#{suffix}"

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

    repo =
      database
      |> runtime_repo_config(restricted_role)
      |> then(&start_supervised!({Repo, &1}))

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

  @spec count_deltas(map(), map()) :: map()
  def count_deltas(before, after_counts) do
    Map.new(before, fn {key, count} -> {key, Map.fetch!(after_counts, key) - count} end)
  end

  @spec run_concurrently(pid(), [(-> result)]) :: [result] when result: var
  def run_concurrently(repo, operations) do
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
          5_000 -> flunk("concurrency worker did not become ready")
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
        migration_source(),
        :up,
        all: true,
        dynamic_repo: migrator_repo,
        log: false
      )
    after
      Supervisor.stop(migrator_repo)
    end
  end

  defp migration_source do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&migration_entry/1)
  end

  defp migration_entry(path) do
    {version, "_" <> _name} = path |> Path.basename() |> Integer.parse()

    [module_name] =
      Regex.run(~r/^defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/m, File.read!(path),
        capture: :all_but_first
      )

    module = loaded_migration_module(path, module_name)

    {version, module}
  end

  defp loaded_migration_module(path, module_name) do
    with {:ok, module} <- existing_module(module_name),
         true <- Code.ensure_loaded?(module) do
      module
    else
      _not_loaded -> require_migration_module!(path)
    end
  end

  defp require_migration_module!(path) do
    case Enum.find(Code.require_file(path), fn {module, _bytecode} ->
           function_exported?(module, :__migration__, 0)
         end) do
      {module, _bytecode} -> module
      nil -> raise "migration module not found in #{path}"
    end
  end

  defp existing_module(module_name) do
    {:ok, String.to_existing_atom("Elixir." <> module_name)}
  rescue
    ArgumentError -> :error
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

      Postgrex.query!(
        admin,
        "REVOKE INSERT, UPDATE, DELETE ON schema_migrations FROM #{role}",
        []
      )

      Postgrex.query!(admin, "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO #{role}", [])
    end)
  end

  defp runtime_repo_config(database, role) do
    Repo.config()
    |> Keyword.put(:database, database)
    |> Keyword.put(:name, nil)
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 6)
    |> Keyword.put(:after_connect, {Postgrex, :query!, ["SET ROLE #{role}", []]})
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
