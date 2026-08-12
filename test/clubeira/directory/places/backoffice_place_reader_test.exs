defmodule Clubeira.Directory.BackofficePlaceReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
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

  test "the detail returns the complete persisted profile without hiding retired selections" do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    restaurant =
      Factory.insert(:place_category,
        key: "restaurant",
        name: "Restaurante",
        display_order: 20
      )

    cafe =
      Factory.insert(:place_category,
        key: "cafe",
        name: "Cafe",
        display_order: 10
      )

    assert {:ok, _result} =
             Directory.publish_place_profile(scope, fixture.ids.place, %{
               contact: %{email: "contato@perfil.example", phone: "+55 88 99999-0101"},
               category_keys: [restaurant.key, cafe.key],
               weekly_hours: [
                 %{weekday: 1, opens_at: "09:00", closes_at: "18:00"},
                 %{weekday: 6, opens_at: "20:00", closes_at: "02:00"}
               ],
               special_hours: [
                 %{date: "2026-12-25", kind: "closed"},
                 %{
                   date: "2026-12-31",
                   kind: "custom",
                   windows: [
                     %{opens_at: "18:00", closes_at: "22:00"},
                     %{opens_at: "23:00", closes_at: "02:00"}
                   ]
                 }
               ],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "backoffice-profile-full-reader"
             })

    cafe
    |> Ecto.Changeset.change(status: "retired")
    |> Repo.update!()

    assert {:ok, %{profile: profile}} =
             Directory.get_backoffice_place(scope, fixture.ids.polo_place)

    assert profile.public_email == "contato@perfil.example"
    assert profile.public_phone == "+5588999990101"

    assert profile.categories == [
             %{key: "cafe", name: "Cafe", status: "retired"},
             %{key: "restaurant", name: "Restaurante", status: "active"}
           ]

    assert profile.weekly_hours == [
             %{
               weekday: 1,
               opens_at: ~T[09:00:00],
               closes_at: ~T[18:00:00],
               closes_next_day: false
             },
             %{
               weekday: 6,
               opens_at: ~T[20:00:00],
               closes_at: ~T[02:00:00],
               closes_next_day: true
             }
           ]

    assert profile.special_hours == [
             %{date: ~D[2026-12-25], kind: "closed", windows: []},
             %{
               date: ~D[2026-12-31],
               kind: "custom",
               windows: [
                 %{
                   opens_at: ~T[18:00:00],
                   closes_at: ~T[22:00:00],
                   closes_next_day: false
                 },
                 %{
                   opens_at: ~T[23:00:00],
                   closes_at: ~T[02:00:00],
                   closes_next_day: true
                 }
               ]
             }
           ]
  end

  test "active categories are authorized and ordered for administrative forms" do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    Factory.insert(:place_category,
      key: "restaurant",
      name: "Restaurante",
      display_order: 20
    )

    Factory.insert(:place_category,
      key: "cafe",
      name: "Cafe",
      display_order: 10
    )

    Factory.insert(:place_category,
      key: "retired",
      name: "Aposentada",
      status: "retired",
      display_order: 0
    )

    assert {:ok,
            [
              %{key: "cafe", name: "Cafe", display_order: 10},
              %{key: "restaurant", name: "Restaurante", display_order: 20}
            ]} = Directory.list_backoffice_place_categories(admin_scope)

    assert {:error, :partner_admin_required} =
             Directory.list_backoffice_place_categories(moderator_scope)
  end
end
