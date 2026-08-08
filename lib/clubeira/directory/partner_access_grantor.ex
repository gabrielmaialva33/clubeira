defmodule Clubeira.Directory.PartnerAccessGrantor do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.OrganizationMembershipRole
  alias Clubeira.Directory.OrganizationRole
  alias Clubeira.Directory.PartnerAccessGrantRequest
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Directory.PlaceStaffAssignment
  alias Clubeira.Directory.PlaceStaffAssignmentRole
  alias Clubeira.Directory.PlaceStaffRole
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "directory.grant_partner_access"
  @polo_role_key "partner_manager"
  @organization_role_key "manager"
  @place_role_key "manager"

  @type result :: %{String.t() => term()}

  @spec grant(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def grant(%Scope{actor_user_id: nil}, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  def grant(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, request} <- PartnerAccessGrantRequest.new(attributes) do
      scope
      |> transact_grant(place_id, request)
      |> unwrap_transaction()
    end
  end

  def grant(_scope, _place_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_grant(scope, place_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now),
           {:ok, operated_place} <- fetch_operated_place(repo, scope, place_id, now),
           {:ok, user} <- fetch_verified_user(repo, request.email) do
        reserve_grant(repo, scope, operated_place, user, request, now)
      end
    end)
  end

  defp reserve_grant(repo, scope, operated_place, user, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, operated_place.place.id, user.id),
           now
         ) do
      {:new, idempotency_id} ->
        grant_new!(repo, scope, operated_place, user, idempotency_id, now)

      {:replay, key} ->
        {:ok, replay(key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_new!(repo, scope, operated_place, user, idempotency_id, now) do
    case current_polo_membership(repo, scope.polo_id, user.id, now) do
      nil ->
        access = create_access!(repo, scope, operated_place, user, now)
        result = Map.delete(access, "staff_assignment_id")

        record_grant!(repo, scope, access, now)

        Idempotency.complete!(
          repo,
          idempotency_id,
          "partner_access",
          result["id"],
          result,
          now
        )

        {:ok, {:accepted, result}}

      %PoloMembership{} ->
        {:error, :partner_user_has_polo_access}
    end
  end

  defp create_access!(repo, scope, operated_place, user, now) do
    polo_role = ensure_polo_role!(repo, scope.polo_id, now)
    organization_role = ensure_organization_role!(repo, operated_place.organization.id, now)
    place_role = ensure_place_role!(repo, operated_place.place.id, now)

    organization_membership =
      ensure_organization_membership!(repo, operated_place.organization.id, user.id, now)

    ensure_organization_membership_role!(
      repo,
      operated_place.organization.id,
      organization_membership.id,
      organization_role.id,
      now
    )

    staff_assignment =
      ensure_staff_assignment!(
        repo,
        operated_place,
        organization_membership.id,
        user.id,
        now
      )

    ensure_staff_assignment_role!(
      repo,
      operated_place.place.id,
      staff_assignment.id,
      place_role.id,
      now
    )

    polo_membership =
      %PoloMembership{
        polo_id: scope.polo_id,
        user_id: user.id,
        valid_during: active_range(now),
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    %PoloMembershipRole{
      polo_id: scope.polo_id,
      polo_membership_id: polo_membership.id,
      polo_role_id: polo_role.id,
      inserted_at: now
    }
    |> repo.insert!()

    %{
      "id" => polo_membership.id,
      "organization_id" => operated_place.organization.id,
      "place_id" => operated_place.place.id,
      "role" => @polo_role_key,
      "staff_assignment_id" => staff_assignment.id,
      "status" => "active",
      "user_id" => user.id
    }
  end

  defp ensure_polo_role!(repo, polo_id, now) do
    ensure_role!(
      repo,
      PoloRole,
      %{
        id: uuid7(),
        polo_id: polo_id,
        key: @polo_role_key,
        name: "Gestão de parceiro",
        status: "active",
        inserted_at: now,
        updated_at: now
      },
      [:polo_id, :key],
      polo_id: polo_id,
      key: @polo_role_key
    )
  end

  defp ensure_organization_role!(repo, organization_id, now) do
    ensure_role!(
      repo,
      OrganizationRole,
      %{
        id: uuid7(),
        organization_id: organization_id,
        key: @organization_role_key,
        name: "Gestão da organização",
        status: "active",
        inserted_at: now,
        updated_at: now
      },
      [:organization_id, :key],
      organization_id: organization_id,
      key: @organization_role_key
    )
  end

  defp ensure_place_role!(repo, place_id, now) do
    ensure_role!(
      repo,
      PlaceStaffRole,
      %{
        id: uuid7(),
        place_id: place_id,
        key: @place_role_key,
        name: "Gestão do estabelecimento",
        status: "active",
        inserted_at: now,
        updated_at: now
      },
      [:place_id, :key],
      place_id: place_id,
      key: @place_role_key
    )
  end

  defp ensure_role!(repo, schema, attributes, conflict_target, lookup) do
    repo.insert_all(schema, [attributes],
      on_conflict: :nothing,
      conflict_target: conflict_target
    )

    case repo.get_by!(schema, lookup) do
      %{status: "active"} = role -> role
      _retired -> repo.rollback(:partner_role_unavailable)
    end
  end

  defp ensure_organization_membership!(repo, organization_id, user_id, now) do
    membership =
      OrganizationMembership
      |> where(
        [membership],
        membership.organization_id == ^organization_id and membership.user_id == ^user_id and
          membership.status == "active"
      )
      |> where(
        [membership],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          membership.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    membership ||
      %OrganizationMembership{
        organization_id: organization_id,
        user_id: user_id,
        valid_during: active_range(now),
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()
  end

  defp ensure_organization_membership_role!(
         repo,
         organization_id,
         membership_id,
         role_id,
         now
       ) do
    %OrganizationMembershipRole{
      organization_id: organization_id,
      organization_membership_id: membership_id,
      organization_role_id: role_id,
      inserted_at: now
    }
    |> repo.insert(on_conflict: :nothing)

    :ok
  end

  defp ensure_staff_assignment!(repo, operated_place, membership_id, user_id, now) do
    assignment =
      PlaceStaffAssignment
      |> where(
        [assignment],
        assignment.place_id == ^operated_place.place.id and assignment.user_id == ^user_id and
          assignment.organization_id == ^operated_place.organization.id and
          assignment.status == "active"
      )
      |> where(
        [assignment],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          assignment.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    assignment ||
      %PlaceStaffAssignment{
        place_id: operated_place.place.id,
        organization_id: operated_place.organization.id,
        user_id: user_id,
        organization_membership_id: membership_id,
        valid_during: active_range(now),
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()
  end

  defp ensure_staff_assignment_role!(repo, place_id, assignment_id, role_id, now) do
    %PlaceStaffAssignmentRole{
      place_id: place_id,
      place_staff_assignment_id: assignment_id,
      place_staff_role_id: role_id,
      inserted_at: now
    }
    |> repo.insert(on_conflict: :nothing)

    :ok
  end

  defp current_polo_membership(repo, polo_id, user_id, now) do
    PoloMembership
    |> where(
      [membership],
      membership.polo_id == ^polo_id and membership.user_id == ^user_id and
        membership.status in ["invited", "active", "suspended"]
    )
    |> where(
      [membership],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        membership.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp fetch_active_polo(repo, polo_id) do
    case Polo |> where([polo], polo.id == ^polo_id) |> lock("FOR SHARE") |> repo.one() do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp fetch_operated_place(repo, scope, place_id, now) do
    operated_place =
      PoloPlace
      |> join(:inner, [participation], place in Place, on: place.id == participation.place_id)
      |> join(:inner, [_participation, place], operator in PlaceOperator,
        on: operator.place_id == place.id and operator.role == "operator"
      )
      |> join(:inner, [_participation, _place, operator], organization in Organization,
        on: organization.id == operator.organization_id
      )
      |> where([participation], participation.polo_id == ^scope.polo_id)
      |> where(
        [participation],
        participation.place_id == ^place_id and participation.status == "active"
      )
      |> where(
        [participation],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          participation.participation_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> where([_participation, place], place.status == "active")
      |> where(
        [_participation, _place, operator],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          operator.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> where(
        [_participation, _place, _operator, organization],
        organization.status == "active"
      )
      |> select([participation, place, operator, organization], %{
        participation: participation,
        place: place,
        operator: operator,
        organization: organization
      })
      |> lock("FOR SHARE")
      |> repo.one()

    if operated_place, do: {:ok, operated_place}, else: {:error, :place_not_found}
  end

  defp fetch_verified_user(repo, email) do
    user =
      User
      |> where(
        [user],
        user.email == ^email and user.status == "active" and not is_nil(user.email_verified_at)
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    if user, do: {:ok, user}, else: {:error, :partner_user_not_found}
  end

  defp record_grant!(repo, scope, result, now) do
    payload = %{
      "organization_id" => result["organization_id"],
      "place_id" => result["place_id"],
      "staff_assignment_id" => result["staff_assignment_id"],
      "user_id" => result["user_id"],
      "granted_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "partner_access",
      aggregate_id: result["id"],
      aggregate_version: 1,
      event_type: "partner_access.granted",
      topic: "partners.access.granted",
      message_key: result["id"],
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "partner_access.granted",
      resource_type: "partner_access",
      resource_id: result["id"],
      metadata: payload,
      occurred_at: now
    })
  end

  defp replay(%Key{
         status: "completed",
         response_status: 201,
         resource_type: "partner_access",
         response_body: response_body
       })
       when is_map(response_body),
       do: {:accepted, response_body}

  defp replay(key), do: raise("invalid persisted partner access response: #{inspect(key)}")

  defp request_hash(scope, place_id, user_id) do
    Idempotency.fingerprint({1, scope.polo_id, scope.actor_user_id, place_id, user_id})
  end

  defp active_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp cast_place_id(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :place_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
