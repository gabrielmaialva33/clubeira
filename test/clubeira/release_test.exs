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
end
