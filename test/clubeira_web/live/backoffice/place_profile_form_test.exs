defmodule ClubeiraWeb.Backoffice.PlaceProfileFormTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.Backoffice.PlaceProfileForm

  test "sort and drop parameters add and remove complete nested schedule rows" do
    form =
      PlaceProfileForm.from_place(
        %{
          id: Ecto.UUID.generate(),
          profile: nil
        },
        "place-profile-form-dynamic"
      )

    changeset =
      PlaceProfileForm.change(form, %{
        "public_email" => "perfil@example.test",
        "public_phone" => "+5588999990101",
        "category_keys" => ["cafe"],
        "weekly_hours" => %{
          "0" => %{"weekday" => "1", "opens_at" => "09:00", "closes_at" => "18:00"}
        },
        "weekly_hours_sort" => ["0", "new"],
        "weekly_hours_drop" => ["0"],
        "special_hours" => %{
          "0" => %{
            "local_date" => "2026-12-31",
            "kind" => "custom",
            "windows" => %{
              "0" => %{"opens_at" => "18:00", "closes_at" => "22:00"}
            },
            "windows_sort" => ["0", "new"]
          }
        },
        "special_hours_sort" => ["0"]
      })

    updated = Ecto.Changeset.apply_changes(changeset)

    assert [%{weekday: nil, opens_at: nil, closes_at: nil}] = updated.weekly_hours

    assert [
             %{
               local_date: ~D[2026-12-31],
               kind: "custom",
               windows: [
                 %{opens_at: ~T[18:00:00], closes_at: ~T[22:00:00]},
                 %{opens_at: nil, closes_at: nil}
               ]
             }
           ] = updated.special_hours
  end

  test "changing a custom special date to closed removes its obsolete windows" do
    form =
      PlaceProfileForm.from_place(
        %{
          id: Ecto.UUID.generate(),
          profile: %{
            revision: 1,
            public_email: "perfil@example.test",
            public_phone: "+5588999990101",
            categories: [%{key: "cafe"}],
            weekly_hours: [
              %{weekday: 1, opens_at: ~T[09:00:00], closes_at: ~T[18:00:00]}
            ],
            special_hours: [
              %{
                date: ~D[2026-12-31],
                kind: "custom",
                windows: [%{opens_at: ~T[20:00:00], closes_at: ~T[02:00:00]}]
              }
            ]
          }
        },
        "place-profile-form-close-date"
      )

    changeset =
      PlaceProfileForm.change(form, %{
        "special_hours" => %{
          "0" => %{"local_date" => "2026-12-31", "kind" => "closed"}
        },
        "special_hours_sort" => ["0"]
      })

    assert [%{kind: "closed", windows: []}] =
             changeset |> Ecto.Changeset.apply_changes() |> Map.fetch!(:special_hours)
  end
end
