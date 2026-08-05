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
    moderate_reviews: ["admin", "review_moderator"]
  }

  @type capability :: :moderate_reviews

  @spec authorize(module(), Scope.t(), capability(), DateTime.t()) ::
          :ok | {:error, :moderator_required}
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

    if authorized?, do: :ok, else: {:error, :moderator_required}
  end

  def authorize(_repo, %Scope{}, :moderate_reviews, _now),
    do: {:error, :moderator_required}
end
