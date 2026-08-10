defmodule Clubeira.People.ConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  import Ecto.Query

  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Factory
  alias Clubeira.People
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  test "concurrent first PUTs converge on one self profile and one audit event", %{repo: repo} do
    user = Factory.insert(:user, email: "concurrent-profile@example.test")
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    attributes = %{
      "display_name" => "Perfil Concorrente",
      "cpf" => "52998224725",
      "phone" => "11999999999"
    }

    results =
      run_concurrently(repo, [
        fn -> People.put_self_profile(scope, attributes) end,
        fn -> People.put_self_profile(scope, attributes) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second
    assert {:ok, ^first} = People.get_self_profile(scope)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.action == "person.self_profile.created"
             ),
             :count
           ) == 1
  end
end
