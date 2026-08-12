defmodule Clubeira.Directory.PartnerAccessReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "lists partner-manager memberships with safe user and place context inside one polo" do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    other_admin_scope = ReviewsFixtures.grant_moderator!(other_polo, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    {other_access, _other_partner} = grant_access!(other_polo, other_admin_scope)

    assert {:ok, %{partner_accesses: [listed], page: %{has_more: false}}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{})

    assert listed.id == access["id"]
    assert listed.status == "active"
    assert listed.user == %{id: partner.id, email: partner.email}
    assert [%{id: place_id, name: place_name}] = listed.places
    assert place_id == fixture.ids.place
    assert is_binary(place_name)
    refute listed.id == other_access["id"]
  end

  test "filters revoked accesses without exposing another polo" do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)

    assert {:ok, _revoked} =
             Directory.revoke_partner_access(admin_scope, access["id"], %{
               "reason" => "Responsável desligado da operação.",
               "idempotency_key" => "reader-partner-revocation"
             })

    assert {:ok, %{partner_accesses: [listed]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{
               "status" => "revoked",
               "email" => partner.email
             })

    assert listed.id == access["id"]
    assert listed.status == "revoked"
    assert %DateTime{} = listed.valid_until
  end

  test "reauthorizes the actor and rejects unsafe filters before querying" do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:error, :partner_admin_required} =
             Directory.list_backoffice_partner_accesses(moderator_scope, %{})

    assert {:error, :invalid_partner_access_status} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"status" => "root"})

    assert {:error, :invalid_partner_access_email} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => "not-an-email"})

    assert {:error, :invalid_partner_access_email} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => <<255>>})

    assert {:error, :invalid_pagination} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"limit" => "101"})
  end

  test "paginates access identities before aggregating their places" do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {first_access, _first_partner} = grant_access!(fixture, admin_scope)
    {second_access, _second_partner} = grant_access_to_operated_place!(fixture, admin_scope)

    assert {:ok,
            %{
              partner_accesses: [%{id: first_page_id}],
              page: %{has_more: true, next_cursor: cursor}
            }} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"limit" => "1"})

    assert is_binary(cursor)

    assert {:ok,
            %{
              partner_accesses: [%{id: second_page_id}],
              page: %{has_more: false, next_cursor: nil}
            }} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{
               "limit" => "1",
               "after" => cursor
             })

    assert MapSet.new([first_page_id, second_page_id]) ==
             MapSet.new([first_access["id"], second_access["id"]])
  end

  defp grant_access!(fixture, admin_scope) do
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, access} =
             Directory.grant_partner_access(admin_scope, fixture.ids.place, %{
               "email" => partner.email,
               "idempotency_key" => "reader-partner-grant-#{Ecto.UUID.generate()}"
             })

    {access, partner}
  end

  defp grant_access_to_operated_place!(fixture, admin_scope) do
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))

    assert {:ok, access} =
             Directory.grant_partner_access(admin_scope, fixture.ids.place, %{
               "email" => partner.email,
               "idempotency_key" => "reader-partner-grant-#{Ecto.UUID.generate()}"
             })

    {access, partner}
  end
end
