defmodule Clubeira.Directory.BackofficePlaceReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "an authorized admin gets one exact polo place participation" do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:ok,
            %{
              id: polo_place_id,
              status: "active",
              revision: 1,
              place: %{id: place_id},
              profile: nil
            }} = Directory.get_backoffice_place(scope, fixture.ids.polo_place)

    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
  end

  test "the detail does not cross polo boundaries and reauthorizes the actor" do
    authorized = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(authorized, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)

    assert {:error, :place_not_found} =
             Directory.get_backoffice_place(admin_scope, other_polo.ids.polo_place)

    assert {:error, :partner_admin_required} =
             Directory.get_backoffice_place(moderator_scope, authorized.ids.polo_place)
  end
end
