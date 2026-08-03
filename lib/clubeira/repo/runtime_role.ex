defmodule Clubeira.Repo.RuntimeRole do
  @moduledoc """
  Validates that a runtime database connection cannot bypass row-level security.

  Production connections run this check through Postgrex's `:after_connect`
  callback. Migration jobs use separate credentials and do not start the
  application with the runtime connection contract.
  """

  @role_query """
  SELECT rolname, rolsuper, rolbypassrls
  FROM pg_roles
  WHERE rolname = current_user
  """

  @spec validate_connection!(pid()) :: :ok
  def validate_connection!(connection) do
    connection
    |> Postgrex.query!(@role_query, [])
    |> validate_result!()
  end

  @doc false
  @spec validate_repo!(module()) :: :ok
  def validate_repo!(repo) do
    result = repo.query!(@role_query)
    validate_result!(result)
  end

  defp validate_result!(%{rows: [[_role, false, false]]}), do: :ok

  defp validate_result!(%{rows: [[role, superuser?, bypass_rls?]]}) do
    raise """
    unsafe Clubeira runtime database role #{inspect(role)}: \
    rolsuper=#{superuser?}, rolbypassrls=#{bypass_rls?}; \
    use a NOSUPERUSER NOBYPASSRLS login
    """
  end

  defp validate_result!(_result) do
    raise "could not inspect the Clubeira runtime database role"
  end
end
