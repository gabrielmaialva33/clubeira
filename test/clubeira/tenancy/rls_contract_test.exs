defmodule Clubeira.Tenancy.RlsContractTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Polos.PoloRoute
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @nullable_polo_tables ~w(
    domain_events
    legal_acceptances
    payment_provider_events
  )

  test "every required polo table has forced RLS and a policy" do
    %{rows: rows} =
      Repo.query!("""
      SELECT
        class.relname,
        attribute.attnotnull,
        class.relrowsecurity,
        class.relforcerowsecurity,
        EXISTS (
          SELECT 1
          FROM pg_policy AS policy
          WHERE policy.polrelid = class.oid
        ) AS has_policy
      FROM pg_class AS class
      JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
      JOIN pg_attribute AS attribute ON attribute.attrelid = class.oid
      WHERE namespace.nspname = 'public'
        AND class.relkind = 'r'
        AND attribute.attname = 'polo_id'
        AND NOT attribute.attisdropped
      ORDER BY class.relname
      """)

    missing_required_rls =
      for [table, _not_null, enabled, forced, has_policy] <- rows,
          not (enabled and forced and has_policy),
          do: table

    assert missing_required_rls == []

    nullable_polo_tables = for [table, false, _enabled, _forced, _has_policy] <- rows, do: table

    assert nullable_polo_tables == @nullable_polo_tables
  end

  test "global polo routing exposes only the address needed to enter RLS" do
    assert %{rows: [["polo_id"], ["slug"], ["inserted_at"], ["updated_at"]]} =
             Repo.query!("""
             SELECT column_name
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'polo_routes'
             ORDER BY ordinal_position
             """)

    assert %{rows: [[true, true]]} =
             Repo.query!("""
             SELECT
               EXISTS (
                 SELECT 1
                 FROM pg_policy AS policy
                 JOIN pg_class AS class ON class.oid = policy.polrelid
                 WHERE class.relname = 'polo_routes'
                   AND policy.polname = 'polo_routes_public_read'
                   AND policy.polcmd = 'r'
               ),
               EXISTS (
                 SELECT 1
                 FROM pg_policy AS policy
                 JOIN pg_class AS class ON class.oid = policy.polrelid
                 WHERE class.relname = 'polo_routes'
                   AND policy.polname = 'polo_routes_scoped_write'
                   AND policy.polcmd = '*'
               )
             """)
  end

  test "polo routes are globally readable but cannot be mutated without tenant scope" do
    fixture = RedemptionsFixtures.create!()

    assert %PoloRoute{slug: slug} = Repo.get!(PoloRoute, fixture.ids.polo)
    assert slug == fixture.polo_slug

    assert {0, nil} =
             Repo.update_all(
               from(route in PoloRoute, where: route.polo_id == ^fixture.ids.polo),
               set: [slug: "forged-route"]
             )

    assert Repo.get!(PoloRoute, fixture.ids.polo).slug == fixture.polo_slug
  end

  test "the polos root table is protected by forced RLS" do
    assert %{rows: [[true, true, true]]} =
             Repo.query!("""
             SELECT
               class.relrowsecurity,
               class.relforcerowsecurity,
               EXISTS (
                 SELECT 1
                 FROM pg_policy AS policy
                 WHERE policy.polrelid = class.oid
               )
             FROM pg_class AS class
             JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
             WHERE namespace.nspname = 'public'
               AND class.relname = 'polos'
             """)
  end

  test "outbox rows inherit forced tenant isolation through their domain event" do
    assert %{rows: [[true, true, true]]} =
             Repo.query!("""
             SELECT
               class.relrowsecurity,
               class.relforcerowsecurity,
               EXISTS (
                 SELECT 1
                 FROM pg_policy AS policy
                 WHERE policy.polrelid = class.oid
                   AND policy.polname = 'outbox_polo_isolation'
               )
             FROM pg_class AS class
             JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
             WHERE namespace.nspname = 'public'
               AND class.relname = 'outbox_messages'
             """)
  end
end
