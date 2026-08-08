defmodule Clubeira.Repo.RuntimeRole do
  @moduledoc """
  Validates that a runtime database connection cannot bypass row-level security.

  Production connections run this check through Postgrex's `:after_connect`
  callback. Migration jobs use separate credentials and do not start the
  application with the runtime connection contract.
  """

  @role_query """
  SELECT
    role.rolname,
    role.rolsuper,
    role.rolbypassrls,
    has_schema_privilege(current_user, 'public', 'CREATE'),
    EXISTS (
      SELECT 1
      FROM pg_class AS relation
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE pg_has_role(role.oid, relation.relowner, 'MEMBER')
        AND namespace.nspname = 'public'
        AND relation.relkind IN ('r', 'p')
    ),
    NOT EXISTS (
      SELECT 1
      FROM pg_class AS relation
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relkind IN ('r', 'p')
        AND relation.relname <> 'schema_migrations'
        AND NOT (
          has_table_privilege(role.rolname, relation.oid, 'SELECT')
          AND has_table_privilege(role.rolname, relation.oid, 'INSERT')
          AND has_table_privilege(role.rolname, relation.oid, 'UPDATE')
          AND has_table_privilege(role.rolname, relation.oid, 'DELETE')
        )
    ),
    EXISTS (
      SELECT 1
      FROM pg_class AS relation
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relkind IN ('r', 'p')
        AND relation.relname = 'schema_migrations'
        AND has_table_privilege(role.rolname, relation.oid, 'SELECT')
        AND NOT has_table_privilege(role.rolname, relation.oid, 'INSERT')
        AND NOT has_table_privilege(role.rolname, relation.oid, 'UPDATE')
        AND NOT has_table_privilege(role.rolname, relation.oid, 'DELETE')
    )
  FROM pg_roles AS role
  WHERE role.rolname = current_user
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

  defp validate_result!(%{rows: [[_role, false, false, false, false, true, true]]}), do: :ok

  defp validate_result!(%{
         rows: [
           [
             role,
             superuser?,
             bypass_rls?,
             creates_in_public?,
             controls_tables?,
             has_required_table_privileges?,
             migration_metadata_is_read_only?
           ]
         ]
       }) do
    raise """
    unsafe Clubeira runtime database role #{inspect(role)}: \
    rolsuper=#{superuser?}, rolbypassrls=#{bypass_rls?}, \
    creates_in_public=#{creates_in_public?}, \
    owns_or_can_assume_application_table_owner=#{controls_tables?}; \
    has_required_table_privileges=#{has_required_table_privileges?}; \
    migration_metadata_is_read_only=#{migration_metadata_is_read_only?}; \
    use a NOSUPERUSER NOBYPASSRLS login that cannot create, own, or assume ownership roles
    """
  end

  defp validate_result!(_result) do
    raise "could not inspect the Clubeira runtime database role"
  end
end
