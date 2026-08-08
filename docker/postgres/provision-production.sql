\set ON_ERROR_STOP on

-- Run once as the target database administrator before the first migration,
-- and safely rerun after migrations to reconcile grants. Authentication is
-- provisioned out of band (password, certificate, or managed IAM); this file
-- intentionally contains no credential and creates no database.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clubeira_migrator') THEN
    CREATE ROLE clubeira_migrator
      LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOBYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clubeira_app') THEN
    CREATE ROLE clubeira_app
      LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;

ALTER ROLE clubeira_migrator
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOBYPASSRLS;
ALTER ROLE clubeira_app
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;

SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM PUBLIC', current_database())
\gexec
SELECT format(
  'GRANT CONNECT, CREATE, TEMPORARY ON DATABASE %I TO clubeira_migrator',
  current_database()
)
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO clubeira_app', current_database())
\gexec

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO clubeira_migrator;
GRANT USAGE ON SCHEMA public TO clubeira_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO clubeira_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO clubeira_app;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO clubeira_migrator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO clubeira_app;

SELECT 'REVOKE INSERT, UPDATE, DELETE ON TABLE public.schema_migrations FROM clubeira_app'
WHERE to_regclass('public.schema_migrations') IS NOT NULL
\gexec
SELECT 'GRANT SELECT ON TABLE public.schema_migrations TO clubeira_app'
WHERE to_regclass('public.schema_migrations') IS NOT NULL
\gexec

ALTER DEFAULT PRIVILEGES FOR ROLE clubeira_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO clubeira_app;
ALTER DEFAULT PRIVILEGES FOR ROLE clubeira_migrator IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO clubeira_app;
ALTER DEFAULT PRIVILEGES FOR ROLE clubeira_migrator IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE clubeira_migrator IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO clubeira_app;
