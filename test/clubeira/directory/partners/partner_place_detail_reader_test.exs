defmodule Clubeira.Directory.PartnerPlaceDetailReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "returns one exact assigned place with the complete editable profile" do
    fixture = RedemptionsFixtures.create!()
    %{scope: scope} = grant_partner!(fixture)
    category = Factory.insert(:place_category, key: "cafe", name: "Café")

    assert {:ok, _profile} =
             Directory.publish_place_profile(scope, fixture.ids.place, %{
               contact: %{email: "contato@parceiro.example", phone: "+55 88 99999-0101"},
               category_keys: [category.key],
               weekly_hours: [%{weekday: 1, opens_at: "09:00", closes_at: "18:00"}],
               special_hours: [%{date: "2026-12-25", kind: "closed"}],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "partner-place-detail-profile"
             })

    assert {:ok, place} = Directory.get_partner_place(scope, fixture.ids.polo_place)
    assert place.id == fixture.ids.polo_place
    assert place.place.id == fixture.ids.place
    assert place.profile.revision == 1
    assert place.profile.categories == [%{key: "cafe", name: "Café", status: "active"}]
    assert [%{weekday: 1, opens_at: ~T[09:00:00]}] = place.profile.weekly_hours
    assert [%{date: ~D[2026-12-25], kind: "closed"}] = place.profile.special_hours

    assert {:ok, categories} = Directory.list_partner_place_categories(scope)
    assert Enum.any?(categories, &(&1.key == "cafe"))
  end

  test "does not expose another polo or a place without the complete affiliation chain" do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    %{scope: scope, organization_membership: membership} = grant_partner!(fixture)

    assert {:error, :place_not_found} =
             Directory.get_partner_place(scope, other_polo.ids.polo_place)

    membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    assert {:error, :place_not_found} =
             Directory.get_partner_place(scope, fixture.ids.polo_place)

    assert {:error, :partner_access_required} =
             Directory.list_partner_place_categories(scope)
  end

  test "rejects malformed identities without raising" do
    fixture = RedemptionsFixtures.create!()
    %{scope: scope} = grant_partner!(fixture)

    assert {:error, :place_not_found} = Directory.get_partner_place(scope, "not-a-uuid")
    assert {:error, :partner_access_required} = Directory.get_partner_place(nil, nil)
  end

  defp grant_partner!(fixture) do
    admin = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization, trade_name: "Parceiro do perfil")

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, _access} =
             Directory.grant_partner_access(admin, fixture.ids.place, %{
               "email" => user.email,
               "idempotency_key" => "partner-profile-access-#{uuid7()}"
             })

    organization_membership =
      Repo.get_by!(Clubeira.Directory.OrganizationMembership,
        organization_id: organization.id,
        user_id: user.id
      )

    %{
      organization: organization,
      organization_membership: organization_membership,
      scope: Scope.new!(fixture.ids.polo, actor_user_id: user.id, request_id: uuid7()),
      user: user
    }
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
