defmodule Clubeira.Directory.TimeZoneContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "normalizes persisted IANA time zones behind foreign keys" do
    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT EXISTS (
               SELECT 1
               FROM time_zones
               WHERE name = 'America/Sao_Paulo'
             )
             """)

    assert %{rows: [["cities"], ["places"], ["polos"]]} =
             Repo.query!("""
             SELECT source.relname
             FROM pg_constraint AS con
             JOIN pg_class AS source ON source.oid = con.conrelid
             JOIN pg_class AS target ON target.oid = con.confrelid
             WHERE con.contype = 'f'
               AND source.relname IN ('cities', 'places', 'polos')
               AND target.relname = 'time_zones'
             ORDER BY source.relname
             """)
  end

  test "rejects a polo whose time zone is not present in the IANA catalog" do
    city = insert(:city)
    scope = Scope.new!(Ecto.UUID.generate())

    assert_raise Ecto.ConstraintError, ~r/polos_timezone_fkey/, fn ->
      Repo.transact_in_polo(scope, fn ->
        Repo.insert!(%Polo{
          id: scope.polo_id,
          city: city,
          name: "Invalid time zone",
          timezone: "Mars/Olympus_Mons",
          status: "active"
        })
      end)
    end
  end
end
