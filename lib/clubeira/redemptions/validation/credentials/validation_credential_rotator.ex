defmodule Clubeira.Redemptions.ValidationCredentialRotator do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Place
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationCredentialRotationRequest
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Redemptions.ValidationPointLifecycleLock
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "redemptions.rotate_validation_credential"
  @maximum_credential_lifetime_seconds 365 * 24 * 60 * 60
  @replay_reasons %{
    "credential_already_registered" => :credential_already_registered,
    "validation_credential_revoked" => :validation_credential_revoked,
    "validation_credential_stale" => :validation_credential_stale
  }

  @type result :: %{String.t() => term()}

  @spec rotate(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def rotate(%Scope{actor_user_id: nil}, _credential_id, _attributes),
    do: {:error, :partner_admin_required}

  def rotate(%Scope{} = scope, credential_id, attributes) when is_map(attributes) do
    with {:ok, credential_id} <- cast_credential_id(credential_id),
         {:ok, request} <- ValidationCredentialRotationRequest.new(attributes) do
      scope
      |> transact_rotation(credential_id, request)
      |> unwrap_transaction()
    end
  end

  def rotate(_scope, _credential_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_rotation(scope, credential_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      authorization_time = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, authorization_time) do
        repo
        |> reserve_rotation(scope, credential_id, request, authorization_time)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_rotation(repo, scope, credential_id, request, reservation_time) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, credential_id, request),
           reservation_time
         ) do
      {:new, idempotency_id} ->
        rotate_new(repo, scope, credential_id, request, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rotate_new(repo, scope, credential_id, request, idempotency_id) do
    with {:ok, target} <- fetch_target_credential(repo, scope, credential_id),
         :ok <- ValidationPointLifecycleLock.acquire!(repo, target.validation_point_id),
         {:ok, point} <- lock_rotatable_point(repo, scope, target.validation_point_id),
         :ok <- ensure_active_participation(repo, point),
         now = transaction_time(repo),
         {:ok, current} <- lock_current_credential(repo, scope, point.id),
         :ok <-
           ensure_current_target(repo, scope, current, target, idempotency_id, now),
         :ok <- validate_expiration(request.expires_at, now),
         {:ok, replaced} <-
           transition_current(repo, scope, current, idempotency_id, now) do
      replace_credential(
        repo,
        scope,
        point,
        current,
        replaced,
        request,
        idempotency_id,
        now
      )
    end
  end

  defp replace_credential(
         repo,
         scope,
         point,
         current,
         replaced,
         request,
         idempotency_id,
         now
       ) do
    case insert_credential(repo, scope, point, current, request, now) do
      {:ok, credential} ->
        complete_rotation!(
          repo,
          scope,
          point,
          replaced,
          credential,
          idempotency_id,
          now
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        restore_current!(repo, current, replaced)

        if credential_digest_conflict?(changeset) do
          reject!(repo, scope, current, idempotency_id, :credential_already_registered, now)
        else
          {:error, changeset}
        end
    end
  end

  defp fetch_target_credential(repo, scope, credential_id) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.id == ^credential_id and credential.polo_id == ^scope.polo_id and
          credential.kind == "api_key"
      )
      |> repo.one()

    case credential do
      %ValidationCredential{} -> {:ok, credential}
      nil -> {:error, :validation_credential_not_found}
    end
  end

  defp lock_rotatable_point(repo, scope, validation_point_id) do
    point =
      ValidationPoint
      |> where(
        [point],
        point.id == ^validation_point_id and point.polo_id == ^scope.polo_id and
          point.kind == "api" and point.status in ["active", "suspended"]
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case point do
      %ValidationPoint{} -> {:ok, point}
      nil -> {:error, :validation_point_not_found}
    end
  end

  defp ensure_active_participation(repo, point) do
    active? =
      PoloPlace
      |> join(:inner, [polo_place], place in Place,
        on: place.id == polo_place.place_id and place.status == "active"
      )
      |> where(
        [polo_place],
        polo_place.id == ^point.polo_place_id and polo_place.polo_id == ^point.polo_id and
          polo_place.status == "active"
      )
      |> where(
        [polo_place],
        fragment("? @> statement_timestamp()", polo_place.participation_during)
      )
      |> lock("FOR SHARE")
      |> repo.exists?()

    if active?, do: :ok, else: {:error, :validation_point_not_found}
  end

  defp lock_current_credential(repo, scope, validation_point_id) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.polo_id == ^scope.polo_id and
          credential.validation_point_id == ^validation_point_id and
          credential.kind == "api_key"
      )
      |> order_by([credential], desc: credential.version)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> repo.one()

    case credential do
      %ValidationCredential{} -> {:ok, credential}
      nil -> {:error, :validation_credential_not_found}
    end
  end

  defp ensure_current_target(
         _repo,
         _scope,
         %ValidationCredential{id: id},
         %ValidationCredential{id: id},
         _idempotency_id,
         _now
       ),
       do: :ok

  defp ensure_current_target(repo, scope, current, _target, idempotency_id, now) do
    reject!(repo, scope, current, idempotency_id, :validation_credential_stale, now)
  end

  defp transition_current(
         repo,
         scope,
         %ValidationCredential{} = credential,
         idempotency_id,
         now
       ) do
    cond do
      credential.status == "revoked" ->
        reject!(
          repo,
          scope,
          credential,
          idempotency_id,
          :validation_credential_revoked,
          now
        )

      credential.status == "active" and active_at?(credential.valid_during, now) ->
        replaced =
          credential
          |> Ecto.Changeset.change(
            status: "revoked",
            valid_during: close_range(credential.valid_during, now)
          )
          |> repo.update!()

        {:ok, replaced}

      ended_at_or_before?(credential.valid_during, now) ->
        replaced =
          if credential.status == "active" do
            credential
            |> Ecto.Changeset.change(status: "expired")
            |> repo.update!()
          else
            credential
          end

        {:ok, replaced}

      true ->
        {:error, :validation_credential_unavailable}
    end
  end

  defp ended_at_or_before?(%Postgrex.Range{upper: :unbound}, _now), do: false

  defp ended_at_or_before?(%Postgrex.Range{upper: upper}, now) do
    DateTime.compare(upper, now) in [:lt, :eq]
  end

  defp insert_credential(repo, scope, point, current, request, now) do
    %ValidationCredential{
      polo_id: scope.polo_id,
      validation_point_id: point.id,
      version: current.version + 1,
      kind: "api_key",
      secret_hash: ValidationCredentialRotationRequest.secret_hash(request),
      valid_during: active_range(now, request.expires_at),
      status: "active",
      inserted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:secret_hash,
      name: :validation_credentials_secret_hash_uidx
    )
    |> repo.insert(mode: :savepoint)
  end

  defp complete_rotation!(repo, scope, point, replaced, credential, idempotency_id, now) do
    point = bump_point_revision!(repo, point, now)
    result = response_data(point, replaced, credential)

    record_rotation!(repo, scope, point, replaced, credential, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "validation_credential",
      credential.id,
      result,
      now
    )

    {:accepted, result}
  end

  defp bump_point_revision!(repo, point, now) do
    point
    |> Ecto.Changeset.change(revision: point.revision + 1, updated_at: now)
    |> repo.update!()
  end

  defp record_rotation!(repo, scope, point, replaced, credential, now) do
    payload = %{
      "validation_point_id" => point.id,
      "replaced_credential_id" => replaced.id,
      "replaced_credential_version" => replaced.version,
      "validation_credential_id" => credential.id,
      "credential_kind" => credential.kind,
      "credential_version" => credential.version,
      "credential_expires_at" => DateTime.to_iso8601(credential.valid_during.upper),
      "rotated_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "validation_point",
      aggregate_id: point.id,
      aggregate_version: point.revision,
      event_type: "validation_credential.rotated",
      topic: "redemptions.validation_credentials.rotated",
      message_key: point.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "validation_credential.rotated",
      resource_type: "validation_credential",
      resource_id: credential.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp fetch_active_polo(repo, polo_id) do
    polo =
      Polo
      |> where([polo], polo.id == ^polo_id)
      |> lock("FOR SHARE")
      |> repo.one()

    case polo do
      %Polo{status: "active"} -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp validate_expiration(expires_at, now) do
    lifetime_seconds = DateTime.diff(expires_at, now, :second)

    if lifetime_seconds in 1..@maximum_credential_lifetime_seconds,
      do: :ok,
      else: {:error, :invalid_expiration}
  end

  defp replay(%Key{
         status: "completed",
         response_status: 201,
         resource_type: "validation_credential",
         response_body:
           %{
             "validation_point_id" => point_id,
             "replaced_credential_id" => replaced_id,
             "credential" => %{"id" => credential_id}
           } = response_body
       })
       when is_binary(point_id) and is_binary(replaced_id) and is_binary(credential_id),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key),
    do: raise("invalid persisted validation credential rotation response: #{inspect(key)}")

  defp request_hash(scope, credential_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      credential_id,
      ValidationCredentialRotationRequest.secret_hash(request),
      request.expires_at
    })
  end

  defp restore_current!(repo, current, replaced) do
    replaced
    |> Ecto.Changeset.change(
      status: current.status,
      valid_during: current.valid_during
    )
    |> repo.update!()

    :ok
  end

  defp credential_digest_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:secret_hash, {_message, options}} ->
        options[:constraint] == :unique and
          options[:constraint_name] == "validation_credentials_secret_hash_uidx"

      _other ->
        false
    end)
  end

  defp reject!(repo, scope, current, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "validation_credential",
      current.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "validation_credential.rotation_rejected",
      resource_type: "validation_credential",
      resource_id: current.id,
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp active_at?(%Postgrex.Range{lower: lower, upper: :unbound}, now),
    do: DateTime.compare(lower, now) in [:lt, :eq]

  defp active_at?(%Postgrex.Range{lower: lower, upper: upper}, now) do
    DateTime.compare(lower, now) in [:lt, :eq] and DateTime.compare(now, upper) == :lt
  end

  defp close_range(range, now) do
    %{range | upper: now, upper_inclusive: false}
  end

  defp active_range(now, expires_at) do
    %Postgrex.Range{
      lower: now,
      upper: expires_at,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp response_data(point, replaced, credential) do
    %{
      "validation_point_id" => point.id,
      "replaced_credential_id" => replaced.id,
      "credential" => %{
        "id" => credential.id,
        "version" => credential.version,
        "kind" => credential.kind,
        "status" => credential.status,
        "valid_from" => DateTime.to_iso8601(credential.valid_during.lower),
        "expires_at" => DateTime.to_iso8601(credential.valid_during.upper)
      }
    }
  end

  defp cast_credential_id(credential_id) do
    case Ecto.UUID.cast(credential_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :validation_credential_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
