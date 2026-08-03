defmodule Clubeira.TestDatabaseRole do
  @moduledoc false

  alias Clubeira.Repo

  @spec assume_restricted!() :: String.t()
  def assume_restricted! do
    role = "clubeira_test_#{System.unique_integer([:positive, :monotonic])}"

    Repo.query!(
      "CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
    )

    Repo.query!("GRANT USAGE ON SCHEMA public TO #{role}")
    Repo.query!("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
    Repo.query!("SET LOCAL ROLE #{role}")

    role
  end
end
