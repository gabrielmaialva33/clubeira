defmodule Clubeira.Polos.ActorAccessReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.OrganizationMembershipRole
  alias Clubeira.Directory.OrganizationRole
  alias Clubeira.Platform.Authorization, as: PlatformAuthorization
  alias Clubeira.Polos.Authorization, as: PoloAuthorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @spec get(AccountScope.t()) :: {:ok, map()} | {:error, term()}
  def get(%AccountScope{} = account_scope) do
    actor_scope = ActorScope.new!(account_scope.user.id, account_scope.request_id)

    Repo.transact_as_actor(actor_scope, fn repo ->
      now = transaction_time(repo)
      platform_roles = platform_roles(repo, account_scope.user.id, now)

      {:ok,
       %{
         platform: %{
           roles: platform_roles,
           capabilities: PlatformAuthorization.capabilities_for_role_keys(platform_roles)
         },
         polos: polo_access(repo, account_scope.user.id, now)
       }}
    end)
  end

  defp polo_access(repo, user_id, now) do
    PoloMembership
    |> join(:inner, [membership], assignment in PoloMembershipRole,
      on:
        assignment.polo_membership_id == membership.id and
          assignment.polo_id == membership.polo_id
    )
    |> join(:inner, [_membership, assignment], role in PoloRole,
      on: role.id == assignment.polo_role_id and role.polo_id == assignment.polo_id
    )
    |> join(:inner, [membership], polo in Polo, on: polo.id == membership.polo_id)
    |> join(:inner, [membership], route in PoloRoute, on: route.polo_id == membership.polo_id)
    |> where([membership], membership.user_id == ^user_id and membership.status == "active")
    |> where(
      [membership],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        membership.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> where([_membership, _assignment, role], role.status == "active")
    |> order_by([_membership, _assignment, role, _polo, route],
      asc: route.slug,
      asc: role.key
    )
    |> select([_membership, _assignment, role, polo, route], %{
      id: polo.id,
      slug: route.slug,
      name: polo.name,
      timezone: polo.timezone,
      status: polo.status,
      role: role.key
    })
    |> repo.all()
    |> Enum.chunk_by(& &1.id)
    |> Enum.map(&polo_access_data/1)
  end

  defp polo_access_data([first | _rest] = rows) do
    roles = rows |> Enum.map(& &1.role) |> Enum.uniq()

    %{
      id: first.id,
      slug: first.slug,
      name: first.name,
      timezone: first.timezone,
      status: first.status,
      roles: roles,
      capabilities: PoloAuthorization.capabilities_for_role_keys(roles)
    }
  end

  defp platform_roles(repo, user_id, now) do
    OrganizationMembership
    |> join(:inner, [membership], organization in Organization,
      on: organization.id == membership.organization_id
    )
    |> join(:inner, [membership], assignment in OrganizationMembershipRole,
      on:
        assignment.organization_membership_id == membership.id and
          assignment.organization_id == membership.organization_id
    )
    |> join(:inner, [_membership, _organization, assignment], role in OrganizationRole,
      on:
        role.id == assignment.organization_role_id and
          role.organization_id == assignment.organization_id
    )
    |> where(
      [membership, organization, _assignment, role],
      membership.user_id == ^user_id and membership.status == "active" and
        organization.kind == "platform" and organization.status == "active" and
        role.status == "active"
    )
    |> where(
      [membership],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        membership.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> order_by([_membership, _organization, _assignment, role], asc: role.key)
    |> select([_membership, _organization, _assignment, role], role.key)
    |> distinct(true)
    |> repo.all()
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
