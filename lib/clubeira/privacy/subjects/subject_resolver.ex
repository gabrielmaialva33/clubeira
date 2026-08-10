defmodule Clubeira.Privacy.SubjectResolver do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.People.Person
  alias Clubeira.People.UserPersonLink

  @spec fetch_self(module(), Ecto.UUID.t()) ::
          {:ok, Person.t()} | {:error, :profile_required}
  def fetch_self(repo, actor_user_id) do
    case repo.one(self_person_query(actor_user_id)) do
      %Person{} = person -> {:ok, person}
      nil -> {:error, :profile_required}
    end
  end

  @spec lock_self(module(), Ecto.UUID.t()) ::
          {:ok, Person.t()} | {:error, :profile_required}
  def lock_self(repo, actor_user_id) do
    case repo.one(self_person_query(actor_user_id) |> lock("FOR UPDATE")) do
      %Person{} = person -> {:ok, person}
      nil -> {:error, :profile_required}
    end
  end

  defp self_person_query(actor_user_id) do
    from(link in UserPersonLink,
      join: person in Person,
      on: person.id == link.person_id,
      where:
        link.user_id == ^actor_user_id and link.relationship == "self" and
          link.status == "active",
      select: person
    )
  end
end
