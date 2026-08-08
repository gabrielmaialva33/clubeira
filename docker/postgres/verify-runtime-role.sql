\set ON_ERROR_STOP on

SELECT NOT rolsuper AND NOT rolbypassrls AS runtime_role_is_restricted
FROM pg_roles
WHERE rolname = current_user
\gset

\if :runtime_role_is_restricted
\else
  \echo 'runtime role must be NOSUPERUSER NOBYPASSRLS'
  \quit 1
\endif

SELECT
  has_schema_privilege(current_user, 'public', 'USAGE')
  AND NOT has_schema_privilege(current_user, 'public', 'CREATE')
  AS runtime_schema_privileges_are_restricted
\gset

\if :runtime_schema_privileges_are_restricted
\else
  \echo 'runtime role must have USAGE without CREATE on public schema'
  \quit 1
\endif

SELECT NOT EXISTS (
  SELECT 1
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE pg_has_role(
      (SELECT oid FROM pg_roles WHERE rolname = current_user),
      relation.relowner,
      'MEMBER'
    )
    AND namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p')
) AS runtime_role_controls_no_application_tables
\gset

\if :runtime_role_controls_no_application_tables
\else
  \echo 'runtime role must not own or be a member of roles that own application tables'
  \quit 1
\endif

SELECT NOT EXISTS (
  SELECT 1
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p')
    AND relation.relname <> 'schema_migrations'
    AND NOT (
      has_table_privilege(current_user, relation.oid, 'SELECT')
      AND has_table_privilege(current_user, relation.oid, 'INSERT')
      AND has_table_privilege(current_user, relation.oid, 'UPDATE')
      AND has_table_privilege(current_user, relation.oid, 'DELETE')
    )
) AS runtime_has_required_table_privileges
\gset

\if :runtime_has_required_table_privileges
\else
  \echo 'runtime role is missing required privileges on an application table'
  \quit 1
\endif

SELECT
  has_table_privilege(current_user, 'public.schema_migrations', 'SELECT')
  AND NOT has_table_privilege(current_user, 'public.schema_migrations', 'INSERT')
  AND NOT has_table_privilege(current_user, 'public.schema_migrations', 'UPDATE')
  AND NOT has_table_privilege(current_user, 'public.schema_migrations', 'DELETE')
  AS migration_metadata_is_read_only
\gset

\if :migration_metadata_is_read_only
\else
  \echo 'runtime role must not mutate schema_migrations'
  \quit 1
\endif

SELECT NOT EXISTS (
  SELECT 1
  FROM pg_proc AS function
  JOIN pg_namespace AS namespace ON namespace.oid = function.pronamespace
  WHERE namespace.nspname = 'public'
    AND (
      NOT has_function_privilege(current_user, function.oid, 'EXECUTE')
      OR NOT has_function_privilege('clubeira_migrator', function.oid, 'EXECUTE')
    )
) AS application_functions_are_executable_by_expected_roles
\gset

\if :application_functions_are_executable_by_expected_roles
\else
  \echo 'runtime or migrator role is missing EXECUTE on a public function'
  \quit 1
\endif

SELECT NOT EXISTS (
  SELECT 1
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p')
    AND relation.relrowsecurity
    AND (
      NOT relation.relforcerowsecurity
      OR NOT EXISTS (
        SELECT 1
        FROM pg_policy AS policy
        WHERE policy.polrelid = relation.oid
      )
    )
) AS every_rls_table_is_forced_and_has_a_policy
\gset

\if :every_rls_table_is_forced_and_has_a_policy
\else
  \echo 'an RLS-enabled application table is not forced or has no policy'
  \quit 1
\endif

BEGIN;

SELECT uuidv7() AS city_id, uuidv7() AS polo_id
\gset

INSERT INTO cities (
  id,
  country_code,
  subdivision_code,
  external_code,
  name,
  timezone,
  status
)
VALUES (
  :'city_id',
  'BR',
  'BR-CI',
  'runtime-role-contract',
  'Runtime role contract',
  'America/Sao_Paulo',
  'active'
);

SELECT set_config('app.current_polo_id', :'polo_id', true);

INSERT INTO polos (id, city_id, name, timezone, status)
VALUES (
  :'polo_id',
  :'city_id',
  'Runtime role contract',
  'America/Sao_Paulo',
  'active'
);

INSERT INTO polo_routes (polo_id, slug)
VALUES (:'polo_id', 'runtime-role-contract');

UPDATE polos
SET name = 'Runtime role contract updated'
WHERE id = :'polo_id';

SELECT set_config('app.current_polo_id', '', true);

SELECT count(*) = 1 AS polo_route_is_publicly_readable
FROM polo_routes
WHERE polo_id = :'polo_id'
  AND slug = 'runtime-role-contract'
\gset

\if :polo_route_is_publicly_readable
\else
  \echo 'runtime role cannot resolve a public polo route without tenant scope'
  \quit 1
\endif

SELECT count(*) = 0 AS tenant_row_is_hidden_without_scope
FROM polos
WHERE id = :'polo_id'
\gset

\if :tenant_row_is_hidden_without_scope
\else
  \echo 'runtime role can read a tenant row without polo scope'
  \quit 1
\endif

SELECT set_config('app.current_polo_id', :'polo_id', true);

SELECT count(*) = 1 AS tenant_row_is_visible_with_scope
FROM polos
WHERE id = :'polo_id'
\gset

\if :tenant_row_is_visible_with_scope
\else
  \echo 'runtime role cannot read its tenant row with polo scope'
  \quit 1
\endif

DELETE FROM polo_routes WHERE polo_id = :'polo_id';
DELETE FROM polos WHERE id = :'polo_id';
DELETE FROM cities WHERE id = :'city_id';

ROLLBACK;
