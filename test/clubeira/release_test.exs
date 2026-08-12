defmodule Clubeira.ReleaseTest do
  use ExUnit.Case, async: false

  test "migrations refuse the runtime database role" do
    previous_mode = Application.get_env(:clubeira, :database_role_mode)
    Application.put_env(:clubeira, :database_role_mode, :runtime)

    on_exit(fn ->
      if previous_mode do
        Application.put_env(:clubeira, :database_role_mode, previous_mode)
      else
        Application.delete_env(:clubeira, :database_role_mode)
      end
    end)

    assert_raise RuntimeError, ~r/require CLUBEIRA_DATABASE_ROLE_MODE=migrator/, fn ->
      Clubeira.Release.migrate()
    end

    assert_raise RuntimeError, ~r/require CLUBEIRA_DATABASE_ROLE_MODE=migrator/, fn ->
      Clubeira.Release.bootstrap()
    end
  end

  test "rollback requires an explicit repository and positive version" do
    for {repo, version} <- [{"Clubeira.Repo", 1}, {Clubeira.Repo, 0}, {Clubeira.Repo, -1}] do
      assert_raise ArgumentError, ~r/repository and an explicit positive migration version/, fn ->
        Clubeira.Release.rollback(repo, version)
      end
    end
  end

  test "bootstrap validates the manifest path before opening a repository" do
    previous_mode = Application.get_env(:clubeira, :database_role_mode)
    previous_file = System.get_env("CLUBEIRA_BOOTSTRAP_FILE")
    Application.put_env(:clubeira, :database_role_mode, :migrator)
    System.put_env("CLUBEIRA_BOOTSTRAP_FILE", "relative/bootstrap.json")

    on_exit(fn ->
      restore_application_env(:database_role_mode, previous_mode)
      restore_system_env("CLUBEIRA_BOOTSTRAP_FILE", previous_file)
    end)

    assert_raise RuntimeError, ~r/must point to an absolute regular file/, fn ->
      Clubeira.Release.bootstrap()
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:clubeira, key)
  defp restore_application_env(key, value), do: Application.put_env(:clubeira, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
