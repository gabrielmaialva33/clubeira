defmodule Clubeira.Polos.Authorization do
  @moduledoc """
  Server-derived authorization for staff capabilities inside one polo.

  Role keys are stable authorization identifiers; display names remain local.
  """

  import Ecto.Query

  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Tenancy.Scope

  @capability_roles %{
    manage_billing: ["admin"],
    manage_operations: ["admin"],
    manage_own_places: ["partner_manager"],
    manage_partners: ["admin"],
    moderate_reviews: ["admin", "review_moderator"]
  }

  @type capability ::
          :manage_billing
          | :manage_operations
          | :manage_own_places
          | :manage_partners
          | :moderate_reviews

  @type authorization_error ::
          :billing_admin_required
          | :moderator_required
          | :operations_admin_required
          | :partner_access_required
          | :partner_admin_required

  @spec authorize(module(), Scope.t(), capability(), DateTime.t()) ::
          :ok | {:error, authorization_error()}
  def authorize(repo, %Scope{actor_user_id: actor_user_id} = scope, capability, now)
      when is_binary(actor_user_id) and is_map_key(@capability_roles, capability) do
    role_keys = Map.fetch!(@capability_roles, capability)

    authorized? =
      PoloMembership
      |> join(:inner, [membership], assignment in PoloMembershipRole,
        on:
          assignment.polo_membership_id == membership.id and
            assignment.polo_id == membership.polo_id
      )
      |> join(:inner, [_membership, assignment], role in PoloRole,
        on: role.id == assignment.polo_role_id and role.polo_id == assignment.polo_id
      )
      |> where([membership], membership.polo_id == ^scope.polo_id)
      |> where([membership], membership.user_id == ^actor_user_id)
      |> where([membership], membership.status == "active")
      |> where(
        [membership],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          membership.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> where([_membership, _assignment, role], role.status == "active")
      |> where([_membership, _assignment, role], role.key in ^role_keys)
      |> select([membership], membership.id)
      |> limit(1)
      |> lock("FOR SHARE")
      |> repo.one()
      |> is_binary()

    if authorized?, do: :ok, else: {:error, authorization_error(capability)}
  end

  def authorize(_repo, %Scope{}, :manage_partners, _now),
    do: {:error, :partner_admin_required}

  def authorize(_repo, %Scope{}, :manage_billing, _now),
    do: {:error, :billing_admin_required}

  def authorize(_repo, %Scope{}, :manage_operations, _now),
    do: {:error, :operations_admin_required}

  def authorize(_repo, %Scope{}, :manage_own_places, _now),
    do: {:error, :partner_access_required}

  def authorize(_repo, %Scope{}, :moderate_reviews, _now),
    do: {:error, :moderator_required}

  defp authorization_error(:manage_partners), do: :partner_admin_required
  defp authorization_error(:manage_billing), do: :billing_admin_required
  defp authorization_error(:manage_operations), do: :operations_admin_required
  defp authorization_error(:manage_own_places), do: :partner_access_required
  defp authorization_error(:moderate_reviews), do: :moderator_required
end
