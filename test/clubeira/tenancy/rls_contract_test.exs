defmodule Clubeira.Tenancy.RlsContractTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Devices.UserDeviceAuthorization
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

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

  test "merchant account links are tenant-readable and owner-writable" do
    assert %{rows: rows} =
             Repo.query!("""
             SELECT policy.polname, policy.polcmd
             FROM pg_policy AS policy
             WHERE policy.polrelid = 'public.polo_merchant_accounts'::regclass
             ORDER BY policy.polname
             """)

    assert rows == [
             ["polo_merchant_accounts_owner_delete", "d"],
             ["polo_merchant_accounts_owner_insert", "a"],
             ["polo_merchant_accounts_owner_update", "w"],
             ["polo_merchant_accounts_read", "r"]
           ]

    %{rows: [[read_expression]]} =
      Repo.query!("""
      SELECT pg_get_expr(policy.polqual, policy.polrelid)
      FROM pg_policy AS policy
      WHERE policy.polrelid = 'public.polo_merchant_accounts'::regclass
        AND policy.polname = 'polo_merchant_accounts_read'
      """)

    assert read_expression =~ "app.current_polo_id"
  end

  test "user device authorizations are visible only to their authenticated actor" do
    fixture = RedemptionsFixtures.create!()

    assert %{rows: [[true, true, true]]} =
             Repo.query!("""
             SELECT
               class.relrowsecurity,
               class.relforcerowsecurity,
               EXISTS (
                 SELECT 1
                 FROM pg_policy AS policy
                 WHERE policy.polrelid = class.oid
                   AND policy.polname = 'user_device_authorizations_actor_scope'
               )
             FROM pg_class AS class
             WHERE class.oid = 'public.user_device_authorizations'::regclass
             """)

    assert Repo.aggregate(UserDeviceAuthorization, :count) == 0

    actor_scope = ActorScope.new!(fixture.ids.user, fixture.scope.request_id)

    assert {:ok, 1} =
             Repo.transact_as_actor(actor_scope, fn ->
               {:ok, Repo.aggregate(UserDeviceAuthorization, :count)}
             end)

    other_actor_scope = ActorScope.new!(Ecto.UUID.generate(), Ecto.UUID.generate())

    assert {:ok, 0} =
             Repo.transact_as_actor(other_actor_scope, fn ->
               {:ok, Repo.aggregate(UserDeviceAuthorization, :count)}
             end)
  end
end
