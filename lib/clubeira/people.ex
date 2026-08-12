defmodule Clubeira.People do
  @moduledoc """
  Actor-owned civil identities and write-only sensitive profile attributes.

  Authentication remains in `Clubeira.Accounts`. A person is created lazily
  after signup, and CPF or phone values never leave this boundary once sealed.
  """

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.People.Person
  alias Clubeira.People.PersonContactPoint
  alias Clubeira.People.PersonIdentifier
  alias Clubeira.People.SelfProfileRequest
  alias Clubeira.People.UserPersonLink
  alias Clubeira.Repo
  alias Clubeira.Security.IdentifierVault
  alias Clubeira.Tenancy.ActorScope

  @type profile :: %{
          id: Ecto.UUID.t(),
          display_name: String.t(),
          birth_date: Date.t() | nil,
          status: String.t(),
          identifiers: [map()],
          contact_points: [map()]
        }

  @doc false
  @spec change_self_profile(term()) :: Ecto.Changeset.t()
  def change_self_profile(attributes \\ %{}) do
    SelfProfileRequest.change(attributes)
  end

  @spec put_self_profile(ActorScope.t(), map()) ::
          {:ok, profile()} | {:error, atom() | Ecto.Changeset.t()}
  def put_self_profile(%ActorScope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- SelfProfileRequest.new(attributes) do
      persist_self_profile(scope, request, 1)
    end
  end

  def put_self_profile(%ActorScope{}, attributes), do: SelfProfileRequest.new(attributes)
  def put_self_profile(_scope, _attributes), do: {:error, :invalid_actor_scope}

  defp persist_self_profile(scope, request, retries_left) do
    result = Repo.transact_as_actor(scope, &persist_self_profile_in_scope(&1, scope, request))

    case result do
      {:error, :profile_raced} when retries_left > 0 ->
        persist_self_profile(scope, request, retries_left - 1)

      other ->
        other
    end
  end

  defp persist_self_profile_in_scope(repo, scope, request) do
    now = transaction_time(repo)

    with {:ok, person, created?, person_changed?} <-
           upsert_person(repo, scope.actor_user_id, request, now),
         {:ok, identifier_changed?} <- sync_identifier(repo, person, request, now),
         {:ok, contact_changed?} <- sync_contact(repo, person, request, now) do
      changed? = created? or person_changed? or identifier_changed? or contact_changed?
      record_profile_change(repo, scope, person, created?, person_changed?, changed?, now)
      {:ok, build_profile(repo, person.id)}
    end
  end

  defp record_profile_change(_repo, _scope, _person, _created?, _person_changed?, false, _now),
    do: :ok

  defp record_profile_change(repo, scope, person, created?, person_changed?, true, now) do
    touch_person(repo, person, now, person_changed?)
    record_profile_change!(repo, scope, person, created?, now)
  end

  @spec get_self_profile(ActorScope.t()) ::
          {:ok, profile()} | {:error, :profile_not_found | :invalid_actor_scope}
  def get_self_profile(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      case fetch_self_person(repo, scope.actor_user_id) do
        %Person{} = person -> {:ok, build_profile(repo, person.id)}
        nil -> {:error, :profile_not_found}
      end
    end)
  end

  def get_self_profile(_scope), do: {:error, :invalid_actor_scope}

  defp upsert_person(repo, actor_user_id, request, now) do
    case lock_self_person(repo, actor_user_id) do
      %Person{} = person -> update_person(repo, person, request)
      nil -> create_person(repo, actor_user_id, request, now)
    end
  end

  defp update_person(repo, person, request) do
    changeset =
      Person.profile_changeset(person, %{
        display_name: request.display_name,
        birth_date: request.birth_date
      })

    changed? = changeset.changes != %{}

    case repo.update(changeset) do
      {:ok, updated} -> {:ok, updated, false, changed?}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_person(repo, actor_user_id, request, now) do
    person_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    {1, nil} =
      repo.insert_all(
        Person,
        [
          %{
            id: person_id,
            display_name: request.display_name,
            birth_date: request.birth_date,
            status: "active",
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: false
      )

    case actor_user_id
         |> UserPersonLink.create_changeset(person_id, now)
         |> repo.insert(mode: :savepoint) do
      {:ok, _link} -> {:ok, repo.get!(Person, person_id), true, false}
      {:error, %Ecto.Changeset{}} -> {:error, :profile_raced}
    end
  end

  defp sync_identifier(_repo, _person, %{cpf_supplied?: false}, _now), do: {:ok, false}

  defp sync_identifier(repo, person, %{cpf: nil}, now) do
    revoke_active(repo, PersonIdentifier, person.id, "cpf", now)
  end

  defp sync_identifier(repo, person, %{cpf: cpf}, now) do
    sealed = IdentifierVault.seal("cpf", cpf)

    case active_credential(repo, PersonIdentifier, person.id, "cpf") do
      %PersonIdentifier{lookup_token: lookup_token}
      when lookup_token == sealed.lookup_token ->
        {:ok, false}

      current ->
        revoke(repo, PersonIdentifier, current, now)

        case person.id
             |> PersonIdentifier.create_changeset("cpf", sealed, now)
             |> repo.insert(mode: :savepoint) do
          {:ok, _identifier} -> {:ok, true}
          {:error, %Ecto.Changeset{}} -> {:error, :identifier_conflict}
        end
    end
  end

  defp sync_contact(_repo, _person, %{phone_supplied?: false}, _now), do: {:ok, false}

  defp sync_contact(repo, person, %{phone: nil}, now) do
    revoke_active(repo, PersonContactPoint, person.id, "phone", now)
  end

  defp sync_contact(repo, person, %{phone: phone}, now) do
    sealed = IdentifierVault.seal("phone", phone)

    case active_credential(repo, PersonContactPoint, person.id, "phone") do
      %PersonContactPoint{lookup_token: lookup_token}
      when lookup_token == sealed.lookup_token ->
        {:ok, false}

      current ->
        revoke(repo, PersonContactPoint, current, now)

        case person.id
             |> PersonContactPoint.create_changeset("phone", sealed, now)
             |> repo.insert(mode: :savepoint) do
          {:ok, _contact} -> {:ok, true}
          {:error, %Ecto.Changeset{}} -> {:error, :contact_conflict}
        end
    end
  end

  defp revoke_active(repo, schema, person_id, kind, now) do
    case active_credential(repo, schema, person_id, kind) do
      nil -> {:ok, false}
      current -> revoke(repo, schema, current, now)
    end
  end

  defp revoke(_repo, _schema, nil, _now), do: :ok

  defp revoke(repo, schema, credential, now) do
    updates = [set: [revoked_at: now]]

    updates =
      if schema == PersonContactPoint,
        do: [set: [revoked_at: now, updated_at: now]],
        else: updates

    {1, nil} =
      repo.update_all(
        from(candidate in schema,
          where: candidate.id == ^credential.id and is_nil(candidate.revoked_at)
        ),
        updates
      )

    {:ok, true}
  end

  defp active_credential(repo, schema, person_id, kind) do
    repo.one(
      from(credential in schema,
        where:
          credential.person_id == ^person_id and credential.kind == ^kind and
            is_nil(credential.revoked_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_self_person(repo, actor_user_id) do
    repo.one(
      from(link in UserPersonLink,
        join: person in Person,
        on: person.id == link.person_id,
        where:
          link.user_id == ^actor_user_id and link.relationship == "self" and
            link.status == "active",
        select: person,
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch_self_person(repo, actor_user_id) do
    repo.one(
      from(link in UserPersonLink,
        join: person in Person,
        on: person.id == link.person_id,
        where:
          link.user_id == ^actor_user_id and link.relationship == "self" and
            link.status == "active",
        select: person
      )
    )
  end

  defp build_profile(repo, person_id) do
    person = repo.get!(Person, person_id)

    identifiers =
      repo.all(
        from(identifier in PersonIdentifier,
          where: identifier.person_id == ^person_id and is_nil(identifier.revoked_at),
          order_by: [asc: identifier.kind],
          select: %{kind: identifier.kind, verified_at: identifier.verified_at}
        )
      )

    contacts =
      repo.all(
        from(contact in PersonContactPoint,
          where: contact.person_id == ^person_id and is_nil(contact.revoked_at),
          order_by: [asc: contact.kind],
          select: %{
            kind: contact.kind,
            primary: contact.is_primary,
            verified_at: contact.verified_at
          }
        )
      )

    %{
      id: person.id,
      display_name: person.display_name,
      birth_date: person.birth_date,
      status: person.status,
      identifiers: identifiers,
      contact_points: contacts
    }
  end

  defp touch_person(_repo, _person, _now, true), do: :ok

  defp touch_person(repo, person, now, false) do
    {1, nil} =
      repo.update_all(from(candidate in Person, where: candidate.id == ^person.id),
        set: [updated_at: now]
      )

    :ok
  end

  defp record_profile_change!(repo, scope, person, created?, now) do
    action = if created?, do: "person.self_profile.created", else: "person.self_profile.updated"

    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: action,
      resource_type: "person",
      resource_id: person.id,
      occurred_at: now
    })
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
