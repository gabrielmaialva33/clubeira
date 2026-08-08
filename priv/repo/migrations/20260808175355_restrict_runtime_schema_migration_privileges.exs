defmodule Clubeira.Repo.Migrations.RestrictRuntimeSchemaMigrationPrivileges do
  use Ecto.Migration

  def change do
    execute(
      """
      REVOKE INSERT, UPDATE, DELETE
      ON TABLE public.schema_migrations
      FROM clubeira_app;
      """,
      """
      GRANT INSERT, UPDATE, DELETE
      ON TABLE public.schema_migrations
      TO clubeira_app;
      """
    )

    execute(
      "GRANT SELECT ON TABLE public.schema_migrations TO clubeira_app",
      "GRANT SELECT ON TABLE public.schema_migrations TO clubeira_app"
    )
  end
end
