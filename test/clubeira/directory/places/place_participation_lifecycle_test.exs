defmodule Clubeira.Directory.PlaceParticipationLifecycleTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "builds an empty lifecycle form changeset with the public helper" do
    assert %Ecto.Changeset{valid?: true, changes: %{}} =
             Directory.change_place_participation_lifecycle()
  end

  test "builds an invalid lifecycle form changeset for a non-map payload" do
    changeset = Directory.change_place_participation_lifecycle(:invalid)

    refute changeset.valid?
    assert {"must be a map", []} = changeset.errors[:base]
  end

  test "returns a validation error instead of raising for structured command attributes" do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:error, %Ecto.Changeset{} = changeset} =
             Directory.transition_place_participation(scope, fixture.ids.place, %URI{})

    assert {"must be a map", []} = changeset.errors[:base]
  end

  test "a stale operator revision cannot overwrite a newer participation state" do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:ok, %{"status" => "suspended", "revision" => 2}} =
             Directory.transition_place_participation(scope, fixture.ids.place, %{
               action: "suspend",
               reason: "Pausa operacional confirmada",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-participation-first-operator"
             })

    assert {:error, :stale_place_participation} =
             Directory.transition_place_participation(scope, fixture.ids.place, %{
               action: "retire",
               reason: "Tela antiga não pode aposentar",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-participation-stale-operator"
             })

    assert {:error, :stale_place_participation} =
             Directory.transition_place_participation(scope, fixture.ids.place, %{
               action: "retire",
               reason: "Tela antiga não pode aposentar",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-participation-stale-operator"
             })

    assert {:ok, %{status: "suspended", revision: 2}} =
             Directory.get_backoffice_place(scope, fixture.ids.polo_place)

    assert %{rows: [[1, 1, 0, 0, "1", "2"]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*)
                  FROM tenant_idempotency_keys
                 WHERE scope = 'directory.transition_place_participation'
                   AND idempotency_key = 'place-participation-stale-operator'),
               (SELECT count(*)
                  FROM tenant_audit_events
                 WHERE action = 'polo_place.transition_rejected'),
               (SELECT count(*)
                  FROM domain_events
                 WHERE event_type = 'polo_place.retired'),
               (SELECT count(*)
                  FROM outbox_messages
                 WHERE topic = 'directory.polo_places.retired'),
               (SELECT metadata->>'expected_revision'
                  FROM tenant_audit_events
                 WHERE action = 'polo_place.transition_rejected'),
               (SELECT metadata->>'current_revision'
                  FROM tenant_audit_events
                 WHERE action = 'polo_place.transition_rejected')
             """)
  end

  test "a stale aggregate identity cannot mutate a replacement participation" do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:ok, %{"status" => "retired", "revision" => 2}} =
             Directory.transition_place_participation(scope, fixture.ids.place, %{
               action: "retire",
               reason: "Encerramento da primeira participação",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-participation-first-generation"
             })

    replacement_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               INSERT INTO polo_places (
                 id,
                 city_id,
                 polo_id,
                 place_id,
                 participation_during,
                 status,
                 revision
               )
               VALUES (
                 $1,
                 $2,
                 $3,
                 $4,
                 tstzrange(statement_timestamp(), statement_timestamp() + interval '1 day', '[)'),
                 'active',
                 1
               )
               """,
               [replacement_id, fixture.ids.city, fixture.ids.polo, fixture.ids.place]
             )

    assert {:error, :stale_place_participation} =
             Directory.transition_place_participation(scope, fixture.ids.place, %{
               action: "suspend",
               reason: "Form antigo não pode atingir a nova participação",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-participation-stale-generation"
             })

    assert %{rows: [["retired", 2], ["active", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, revision
               FROM polo_places
               WHERE id IN ($1, $2)
               ORDER BY inserted_at, id
               """,
               [fixture.ids.polo_place, replacement_id]
             )
  end
end
