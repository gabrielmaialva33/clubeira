defmodule Clubeira.Readiness do
  @moduledoc """
  Verifies that a running node can safely serve requests.

  Liveness belongs to the HTTP process. Readiness additionally proves that the
  restricted runtime role is usable and that the database schema is current.
  """

  alias Clubeira.Repo
  alias Clubeira.Repo.RuntimeRole

  @type reason :: {:check_failed, Exception.t()} | {:pending_migrations, [non_neg_integer()]}

  @spec check(keyword()) :: :ok | {:error, reason()}
  def check(options \\ []) do
    repo = Keyword.get(options, :repo, Repo)
    migration_directories = Keyword.get(options, :migration_directories)

    with :ok <- RuntimeRole.validate_repo!(repo) do
      migrations_current(repo, migration_directories)
    end
  rescue
    exception -> {:error, {:check_failed, exception}}
  end

  defp migrations_current(repo, nil) do
    migrations_current(repo, [Ecto.Migrator.migrations_path(repo)])
  end

  defp migrations_current(repo, migration_directories) do
    repo
    |> Ecto.Migrator.migrations(migration_directories,
      skip_table_creation: true,
      migration_lock: false
    )
    |> pending_migrations()
  end

  defp pending_migrations(migrations) do
    case for({:down, version, _name} <- migrations, do: version) do
      [] -> :ok
      versions -> {:error, {:pending_migrations, versions}}
    end
  end
end
