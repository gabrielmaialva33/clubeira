defmodule ClubeiraWeb.Backoffice.PlaceProfileFormTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.Backoffice.PlaceProfileForm
  alias ClubeiraWeb.Backoffice.PlaceProfileForm.SpecialHour

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

  test "builds the replace-all profile command from validated nested fields" do
    polo_place_id = Ecto.UUID.generate()

    form =
      PlaceProfileForm.from_place(
        %{id: polo_place_id, profile: nil},
        "place-profile-form-command"
      )

    changeset =
      PlaceProfileForm.change(form, %{
        "public_email" => "perfil@example.test",
        "public_phone" => "+5588999990101",
        "category_keys" => ["cafe"],
        "weekly_hours" => %{
          "0" => %{"weekday" => "1", "opens_at" => "09:00", "closes_at" => "18:00"}
        },
        "special_hours" => %{
          "0" => %{"local_date" => "2026-12-25", "kind" => "closed"},
          "1" => %{
            "local_date" => "2026-12-31",
            "kind" => "custom",
            "windows" => %{
              "0" => %{"opens_at" => "18:00", "closes_at" => "22:00"}
            }
          }
        }
      })

    assert {:ok,
            %{
              contact: %{email: "perfil@example.test", phone: "+5588999990101"},
              category_keys: ["cafe"],
              expected_polo_place_id: ^polo_place_id,
              expected_revision: 0,
              idempotency_key: "place-profile-form-command",
              weekly_hours: [
                %{weekday: 1, opens_at: "09:00:00", closes_at: "18:00:00"}
              ],
              special_hours: [
                %{date: "2026-12-25", kind: "closed", windows: []},
                %{
                  date: "2026-12-31",
                  kind: "custom",
                  windows: [%{opens_at: "18:00:00", closes_at: "22:00:00"}]
                }
              ]
            }} = PlaceProfileForm.command(changeset)
  end

  test "keeps malformed payloads and mapped domain errors visible" do
    form =
      PlaceProfileForm.from_place(%{id: Ecto.UUID.generate(), profile: nil}, "profile-errors")

    malformed = PlaceProfileForm.change(form, :not_a_map)

    assert {"must be a map", []} = malformed.errors[:base]
    assert {:error, %Ecto.Changeset{}} = PlaceProfileForm.command(malformed)

    form_changeset = PlaceProfileForm.change(form)

    domain_changeset =
      form
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:public_email, "is invalid")
      |> Ecto.Changeset.add_error(:public_phone, "is invalid")
      |> Ecto.Changeset.add_error(:weekly_hours, "overlaps")

    mapped = PlaceProfileForm.put_domain_errors(form_changeset, domain_changeset)

    assert mapped.action == :publish_place_profile
    assert {"is invalid", []} = mapped.errors[:public_email]
    assert {"is invalid", []} = mapped.errors[:public_phone]
    assert {"overlaps", []} = mapped.errors[:weekly_hours]
  end

  test "validates windows according to the special date kind" do
    closed_with_window =
      SpecialHour.changeset(%SpecialHour{}, %{
        "local_date" => "2026-12-25",
        "kind" => "closed",
        "windows" => %{
          "0" => %{"opens_at" => "09:00", "closes_at" => "12:00"}
        }
      })

    custom_without_window =
      SpecialHour.changeset(%SpecialHour{}, %{
        "local_date" => "2026-12-31",
        "kind" => "custom"
      })

    too_many_windows =
      SpecialHour.changeset(%SpecialHour{}, %{
        "local_date" => "2026-12-31",
        "kind" => "custom",
        "windows" =>
          Map.new(0..8, fn index ->
            {Integer.to_string(index), %{"opens_at" => "09:00", "closes_at" => "10:00"}}
          end)
      })

    invalid_kind =
      SpecialHour.changeset(%SpecialHour{}, %{
        "local_date" => "2026-12-31",
        "kind" => "holiday"
      })

    assert {"must be empty when closed", []} = closed_with_window.errors[:windows]
    assert {"must not be empty", []} = custom_without_window.errors[:windows]
    assert {"has too many entries", []} = too_many_windows.errors[:windows]

    assert {"is invalid", validation: :inclusion, enum: ["closed", "custom"]} =
             invalid_kind.errors[:kind]
  end
end
