defmodule Clubeira.Platform.Authorization do
  @moduledoc """
  Authorization for global platform operations backed by current organization roles.
  """

  import Ecto.Query

  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.OrganizationMembershipRole
  alias Clubeira.Directory.OrganizationRole
  alias Clubeira.Tenancy.ActorScope

  @capability_roles %{
    manage_privacy: ~w(privacy_officer platform_admin),
    manage_platform_billing: ~w(platform_billing_admin platform_admin)
  }

  @capability_order [:manage_privacy, :manage_platform_billing]

  @type capability :: :manage_privacy | :manage_platform_billing

  @spec authorize(module(), ActorScope.t(), atom(), DateTime.t()) :: :ok | {:error, atom()}
  def authorize(repo, %ActorScope{} = scope, capability, %DateTime{} = now) do
    case Map.fetch(@capability_roles, capability) do
      {:ok, roles} -> authorize_roles(repo, scope.actor_user_id, roles, now, capability)
      :error -> {:error, :unsupported_platform_capability}
    end
  end

  @doc """
  Derives the stable platform capabilities represented by current role keys.
  """
  @spec capabilities_for_role_keys([String.t()]) :: [capability()]
  def capabilities_for_role_keys(role_keys) when is_list(role_keys) do
    role_keys = MapSet.new(role_keys)

    Enum.filter(@capability_order, fn capability ->
      @capability_roles
      |> Map.fetch!(capability)
      |> Enum.any?(&MapSet.member?(role_keys, &1))
    end)
  end

  defp authorize_roles(repo, actor_user_id, roles, now, capability) do
    authorized? = repo.exists?(authorization_query(actor_user_id, roles, now))

    if authorized?, do: :ok, else: {:error, authorization_error(capability)}
  end

  defp authorization_query(actor_user_id, roles, now) do
    OrganizationMembership
    |> join(:inner, [membership], organization in Organization,
      on: organization.id == membership.organization_id
    )
    |> join(:inner, [membership, _organization], assignment in OrganizationMembershipRole,
      on:
        assignment.organization_id == membership.organization_id and
          assignment.organization_membership_id == membership.id
    )
    |> join(
      :inner,
      [membership, _organization, assignment],
      role in OrganizationRole,
      on:
        role.id == assignment.organization_role_id and
          role.organization_id == assignment.organization_id
    )
    |> where([membership], membership.user_id == ^actor_user_id)
    |> current_membership(now)
    |> active_platform_role(roles)
  end

  defp current_membership(query, now) do
    where(
      query,
      [membership],
      membership.status == "active" and
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          membership.valid_during,
          type(^now, :utc_datetime_usec)
        )
    )
  end

  defp active_platform_role(query, roles) do
    where(
      query,
      [_membership, organization, _assignment, role],
      organization.kind == "platform" and organization.status == "active" and
        role.status == "active" and role.key in ^roles
    )
  end

  defp authorization_error(:manage_privacy), do: :platform_privacy_officer_required
  defp authorization_error(:manage_platform_billing), do: :platform_billing_admin_required
end
