defmodule Clubeira.Release do
  @moduledoc """
  Explicit database tasks for an assembled release.

  These functions are invoked by one-off jobs. They are intentionally absent
  from the application supervision tree so runtime nodes never need migrator
  credentials.
  """

  alias Clubeira.Bootstrap
  alias Clubeira.Bootstrap.Manifest
  alias Clubeira.RuntimeConfig

  @app :clubeira

  @spec migrate() :: :ok
  def migrate do
    load_app()
    ensure_migrator_mode!()

    Enum.each(repos(), fn repo ->
      {:ok, _repo, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @doc """
  Applies the secret-free production bootstrap manifest.

  The command must run as the schema owner because the initial merchant link
  is intentionally not writable by the web role.
  """
  @spec bootstrap() :: :ok
  def bootstrap do
    load_app()
    ensure_migrator_mode!()

    manifest =
      "CLUBEIRA_BOOTSTRAP_FILE"
      |> RuntimeConfig.required_env!()
      |> read_bootstrap_file!()
      |> Jason.decode!()
      |> Manifest.new!()

    Enum.each(repos(), &run_bootstrap(&1, manifest))
  end

  @spec rollback(module(), pos_integer()) :: :ok
  def rollback(repo, version) when is_atom(repo) and is_integer(version) and version > 0 do
    load_app()
    ensure_migrator_mode!()

    {:ok, _repo, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  def rollback(_repo, _version) do
    raise ArgumentError,
          "rollback requires a repository and an explicit positive migration version"
  end

  defp ensure_migrator_mode! do
    if Application.get_env(@app, :database_role_mode) != :migrator do
      raise "Clubeira release database tasks require CLUBEIRA_DATABASE_ROLE_MODE=migrator"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp run_bootstrap(repo, manifest) do
    case Ecto.Migrator.with_repo(repo, fn _repo -> Bootstrap.run(manifest) end) do
      {:ok, {:ok, result}, _apps} ->
        IO.puts(Jason.encode!(result))

      {:ok, {:error, reason}, _apps} ->
        raise "production bootstrap failed: #{inspect(reason)}"

      {:error, reason} ->
        raise "could not start repository for production bootstrap: #{inspect(reason)}"
    end
  end

  defp read_bootstrap_file!(path) do
    unless Path.type(path) == :absolute and File.regular?(path) do
      raise "CLUBEIRA_BOOTSTRAP_FILE must point to an absolute regular file"
    end

    File.read!(path)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
