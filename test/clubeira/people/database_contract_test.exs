defmodule Clubeira.People.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  @actor_owned_tables ~w(
    person_contact_points
    person_identifiers
    persons
    user_person_links
  )

  test "civil identity tables enforce actor RLS" do
    assert %{rows: rows} =
             Repo.query!(
               """
               SELECT
                 class.relname,
                 class.relrowsecurity,
                 class.relforcerowsecurity,
                 count(policy.oid) > 0 AS has_policy
               FROM pg_class AS class
               JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
               LEFT JOIN pg_policy AS policy ON policy.polrelid = class.oid
               WHERE namespace.nspname = 'public'
                 AND class.relname = ANY($1::text[])
               GROUP BY class.relname, class.relrowsecurity, class.relforcerowsecurity
               ORDER BY class.relname
               """,
               [@actor_owned_tables]
             )

    assert rows == Enum.map(@actor_owned_tables, &[&1, true, true, true])
  end

  test "one account can own at most one active self identity" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'user_person_links_active_self_user_uidx'
             """)

    assert definition =~ "UNIQUE INDEX"
    assert definition =~ "(user_id)"
    assert definition =~ "relationship = 'self'"
    assert definition =~ "status = 'active'"
  end
end
