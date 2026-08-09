defmodule Clubeira.Directory.PartnerPlaceAccess do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.OrganizationMembershipRole
  alias Clubeira.Directory.OrganizationRole
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Directory.PlaceStaffAssignment
  alias Clubeira.Directory.PlaceStaffAssignmentRole
  alias Clubeira.Directory.PlaceStaffRole
  alias Clubeira.Polos.Authorization
  alias Clubeira.Tenancy.Scope

  @spec authorize(module(), Scope.t(), Ecto.UUID.t(), DateTime.t()) ::
          :ok | {:error, :partner_access_required | :place_not_found}
  def authorize(repo, %Scope{} = scope, place_id, now) do
    case authorized_organization(repo, scope, place_id, now) do
      {:ok, _organization_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authorized_organization(module(), Scope.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :partner_access_required | :place_not_found}
  def authorized_organization(repo, %Scope{} = scope, place_id, now) do
    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now),
         organization_id when is_binary(organization_id) <-
           assigned_organization(repo, scope, place_id, now) do
      {:ok, organization_id}
    else
      nil -> {:error, :place_not_found}
      {:error, :partner_access_required} = error -> error
    end
  end

  @spec active_place_ids_query(Scope.t(), DateTime.t()) :: Ecto.Query.t()
  def active_place_ids_query(%Scope{} = scope, now) do
    scope
    |> active_assignments_query(now)
    |> select([assignment], %{place_id: assignment.place_id})
    |> distinct(true)
  end

  defp assigned_organization(repo, scope, place_id, now) do
    scope
    |> active_assignments_query(now)
    |> where([assignment: assignment], assignment.place_id == ^place_id)
    |> select([assignment: assignment], assignment.organization_id)
    |> limit(1)
    |> lock("FOR SHARE")
    |> repo.one()
  end

  defp active_assignments_query(scope, now) do
    PlaceStaffAssignment
    |> from(as: :assignment)
    |> join_place_role()
    |> join_organization_role()
    |> join_operator()
    |> filter_active(scope)
    |> filter_current(now)
  end

  defp join_place_role(query) do
    query
    |> join(:inner, [assignment: assignment], assignment_role in PlaceStaffAssignmentRole,
      as: :assignment_role,
      on:
        assignment_role.place_id == assignment.place_id and
          assignment_role.place_staff_assignment_id == assignment.id
    )
    |> join(:inner, [assignment_role: assignment_role], place_role in PlaceStaffRole,
      as: :place_role,
      on:
        place_role.id == assignment_role.place_staff_role_id and
          place_role.place_id == assignment_role.place_id
    )
  end

  defp join_organization_role(query) do
    query
    |> join(:inner, [assignment: assignment], membership in OrganizationMembership,
      as: :organization_membership,
      on:
        membership.id == assignment.organization_membership_id and
          membership.organization_id == assignment.organization_id and
          membership.user_id == assignment.user_id
    )
    |> join(
      :inner,
      [organization_membership: membership],
      membership_role in OrganizationMembershipRole,
      as: :organization_membership_role,
      on:
        membership_role.organization_id == membership.organization_id and
          membership_role.organization_membership_id == membership.id
    )
    |> join(
      :inner,
      [organization_membership_role: membership_role],
      organization_role in OrganizationRole,
      as: :organization_role,
      on:
        organization_role.id == membership_role.organization_role_id and
          organization_role.organization_id == membership_role.organization_id
    )
  end

  defp join_operator(query) do
    query
    |> join(:inner, [assignment: assignment], operator in PlaceOperator,
      as: :operator,
      on:
        operator.place_id == assignment.place_id and
          operator.organization_id == assignment.organization_id and operator.role == "operator"
    )
    |> join(:inner, [assignment: assignment], organization in Organization,
      as: :organization,
      on: organization.id == assignment.organization_id
    )
  end

  defp filter_active(query, scope) do
    query
    |> where(
      [assignment: assignment],
      assignment.user_id == ^scope.actor_user_id and assignment.status == "active"
    )
    |> where(
      [place_role: place_role],
      place_role.key == "manager" and place_role.status == "active"
    )
    |> where([organization_membership: membership], membership.status == "active")
    |> where(
      [organization_role: organization_role],
      organization_role.key == "manager" and organization_role.status == "active"
    )
    |> where([organization: organization], organization.status == "active")
  end

  defp filter_current(query, now) do
    query
    |> where(
      [assignment: assignment],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        assignment.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> where(
      [organization_membership: membership],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        membership.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> where(
      [operator: operator],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        operator.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
  end
end
