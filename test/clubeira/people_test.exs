defmodule Clubeira.PeopleTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Audit.SystemEvent
  alias Clubeira.People
  alias Clubeira.Tenancy.ActorScope

  setup do
    user = insert(:user)
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    %{scope: scope, user: user}
  end

  test "creates and idempotently replaces the authenticated person's self profile", %{
    scope: scope,
    user: user
  } do
    attributes = %{
      "display_name" => "  Ana Beatriz Souza  ",
      "birth_date" => "1993-04-12",
      "cpf" => "529.982.247-25",
      "phone" => "+55 (11) 99999-9999"
    }

    assert {:ok, profile} = People.put_self_profile(scope, attributes)

    assert profile == %{
             id: profile.id,
             display_name: "Ana Beatriz Souza",
             birth_date: ~D[1993-04-12],
             status: "active",
             identifiers: [%{kind: "cpf", verified_at: nil}],
             contact_points: [%{kind: "phone", primary: true, verified_at: nil}]
           }

    assert {:ok, ^profile} = People.get_self_profile(scope)
    assert {:ok, ^profile} = People.put_self_profile(scope, attributes)

    assert {:ok, %{rows: [[1, 1, 1, false, false]]}} =
             Repo.transact_as_actor(scope, fn repo ->
               result =
                 repo.query!("""
                 SELECT
                   (SELECT count(*) FROM persons),
                   (SELECT count(*) FROM person_identifiers),
                   (SELECT count(*) FROM person_contact_points),
                   EXISTS (
                     SELECT 1 FROM person_identifiers
                     WHERE ciphertext = convert_to('52998224725', 'UTF8')
                   ),
                   EXISTS (
                     SELECT 1 FROM person_contact_points
                     WHERE ciphertext = convert_to('+5511999999999', 'UTF8')
                   )
                 """)

               {:ok, result}
             end)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.action == "person.self_profile.created" and
                   event.resource_id == ^profile.id
             ),
             :count
           ) == 1
  end

  test "actor RLS hides civil identity, identifier, contact, and link from another account", %{
    scope: scope
  } do
    assert {:ok, _profile} =
             People.put_self_profile(scope, %{
               "display_name" => "Pessoa Isolada",
               "cpf" => "52998224725",
               "phone" => "11999999999"
             })

    other_user = insert(:user)
    other_scope = ActorScope.new!(other_user.id, Ecto.UUID.generate(version: 7))

    assert {:error, :profile_not_found} = People.get_self_profile(other_scope)

    assert {:ok, %{rows: [[0, 0, 0, 0]]}} =
             Repo.transact_as_actor(other_scope, fn repo ->
               result =
                 repo.query!("""
                 SELECT
                   (SELECT count(*) FROM persons),
                   (SELECT count(*) FROM person_identifiers),
                   (SELECT count(*) FROM person_contact_points),
                   (SELECT count(*) FROM user_person_links)
                 """)

               {:ok, result}
             end)
  end

  test "replaces sensitive values append-only, preserves omissions and revokes explicit nulls", %{
    scope: scope,
    user: user
  } do
    assert {:ok, profile} =
             People.put_self_profile(scope, %{
               "display_name" => "Titular do Perfil",
               "cpf" => "52998224725",
               "phone" => "11999999999"
             })

    assert {:ok, replaced} =
             People.put_self_profile(scope, %{
               "display_name" => "Titular do Perfil",
               "cpf" => "111.444.777-35",
               "phone" => "+55 11 98765-4321"
             })

    assert replaced.id == profile.id
    assert replaced.identifiers == [%{kind: "cpf", verified_at: nil}]
    assert replaced.contact_points == [%{kind: "phone", primary: true, verified_at: nil}]

    assert {:ok, preserved} =
             People.put_self_profile(scope, %{"display_name" => "Titular do Perfil"})

    assert preserved.id == profile.id
    assert preserved.identifiers == [%{kind: "cpf", verified_at: nil}]
    assert preserved.contact_points == [%{kind: "phone", primary: true, verified_at: nil}]

    assert {:ok, cleared} =
             People.put_self_profile(scope, %{
               "display_name" => "Titular do Perfil",
               "cpf" => nil,
               "phone" => nil
             })

    assert cleared.id == profile.id
    assert cleared.identifiers == []
    assert cleared.contact_points == []

    assert {:ok, %{rows: [[2, 2, 2, 2]]}} =
             Repo.transact_as_actor(scope, fn repo ->
               result =
                 repo.query!("""
                 SELECT
                   (SELECT count(*) FROM person_identifiers),
                   (SELECT count(*) FROM person_identifiers WHERE revoked_at IS NOT NULL),
                   (SELECT count(*) FROM person_contact_points),
                   (SELECT count(*) FROM person_contact_points WHERE revoked_at IS NOT NULL)
                 """)

               {:ok, result}
             end)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.resource_id == ^profile.id and
                   event.action == "person.self_profile.updated"
             ),
             :count
           ) == 2
  end

  test "rejects malformed civil data before opening the write transaction", %{scope: scope} do
    assert {:error, changeset} =
             People.put_self_profile(scope, %{
               "display_name" => "A",
               "birth_date" => Date.utc_today() |> Date.add(1) |> Date.to_iso8601(),
               "cpf" => "111.111.111-11",
               "phone" => "123"
             })

    assert %{display_name: [_], birth_date: [_], cpf: [_], phone: [_]} = errors_on(changeset)

    assert {:ok, %{rows: [[0, 0, 0, 0]]}} =
             Repo.transact_as_actor(scope, fn repo ->
               result =
                 repo.query!("""
                 SELECT
                   (SELECT count(*) FROM persons),
                   (SELECT count(*) FROM person_identifiers),
                   (SELECT count(*) FROM person_contact_points),
                   (SELECT count(*) FROM user_person_links)
                 """)

               {:ok, result}
             end)
  end

  test "returns one opaque conflict and rolls back when a CPF belongs to another person", %{
    scope: scope
  } do
    assert {:ok, _profile} =
             People.put_self_profile(scope, %{
               "display_name" => "Primeira Pessoa",
               "cpf" => "52998224725"
             })

    other_user = insert(:user)
    other_scope = ActorScope.new!(other_user.id, Ecto.UUID.generate(version: 7))

    assert {:error, :identifier_conflict} =
             People.put_self_profile(other_scope, %{
               "display_name" => "Segunda Pessoa",
               "cpf" => "529.982.247-25"
             })

    assert {:error, :profile_not_found} = People.get_self_profile(other_scope)

    refute Repo.exists?(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^other_user.id and
                   event.action == "person.self_profile.created"
             )
           )
  end
end
