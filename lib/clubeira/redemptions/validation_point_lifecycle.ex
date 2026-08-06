defmodule Clubeira.Redemptions.ValidationPointLifecycle do
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
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Redemptions.ValidationPointLifecycleLock
  alias Clubeira.Redemptions.ValidationPointLifecycleRequest
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "redemptions.transition_validation_point"
  @replay_reasons %{
    "invalid_validation_point_transition" => :invalid_validation_point_transition,
    "validation_credential_revoked" => :validation_credential_revoked,
    "validation_point_unavailable" => :validation_point_unavailable
  }

  @type result :: %{String.t() => term()}

  @spec transition(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(%Scope{actor_user_id: nil}, _point_id, _attributes),
    do: {:error, :partner_admin_required}

  def transition(%Scope{} = scope, point_id, attributes) when is_map(attributes) do
    with {:ok, point_id} <- cast_point_id(point_id),
         {:ok, request} <- ValidationPointLifecycleRequest.new(attributes) do
      scope
      |> transact_transition(point_id, request)
      |> unwrap_transaction()
    end
  end

  def transition(_scope, _point_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_transition(scope, point_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      authorization_time = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, authorization_time) do
        repo
        |> reserve_transition(scope, point_id, request, authorization_time)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_transition(repo, scope, point_id, request, reservation_time) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, point_id, request),
           reservation_time
         ) do
      {:new, idempotency_id} ->
        transition_new(repo, scope, point_id, request, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition_new(repo, scope, point_id, request, idempotency_id) do
    ValidationPointLifecycleLock.acquire!(repo, point_id)

    with {:ok, point} <- lock_point(repo, scope, point_id) do
      now = transaction_time(repo)

      case transition_point(repo, point, request.action, now) do
        {:ok, updated, credential_transition} ->
          complete_transition!(
            repo,
            scope,
            point,
            updated,
            credential_transition,
            request,
            idempotency_id,
            now
          )

        {:error, reason} ->
          reject!(repo, scope, point, request, idempotency_id, reason, now)
      end
    end
  end

  defp lock_point(repo, scope, point_id) do
    point =
      ValidationPoint
      |> where(
        [point],
        point.id == ^point_id and point.polo_id == ^scope.polo_id and point.kind == "api"
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case point do
      %ValidationPoint{} -> {:ok, point}
      nil -> {:error, :validation_point_not_found}
    end
  end

  defp transition_point(repo, %ValidationPoint{status: "active"} = point, "suspend", now) do
    {:ok, update_status!(repo, point, "suspended", now), nil}
  end

  defp transition_point(repo, %ValidationPoint{status: "suspended"} = point, "reactivate", now) do
    with :ok <- ensure_active_participation(repo, point),
         :ok <- ensure_current_credential_active(repo, point, now) do
      {:ok, update_status!(repo, point, "active", now), nil}
    end
  end

  defp transition_point(repo, %ValidationPoint{status: status} = point, "retire", now)
       when status in ["active", "suspended"] do
    credential_transition = retire_current_credential(repo, point, now)
    {:ok, update_status!(repo, point, "retired", now), credential_transition}
  end

  defp transition_point(_repo, _point, _action, _now),
    do: {:error, :invalid_validation_point_transition}

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

    if active?, do: :ok, else: {:error, :validation_point_unavailable}
  end

  defp ensure_current_credential_active(repo, point, now) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.polo_id == ^point.polo_id and
          credential.validation_point_id == ^point.id and
          credential.kind == "api_key"
      )
      |> order_by([credential], desc: credential.version)
      |> limit(1)
      |> lock("FOR SHARE")
      |> repo.one()

    case credential do
      %ValidationCredential{status: "revoked"} ->
        {:error, :validation_credential_revoked}

      %ValidationCredential{status: "active", valid_during: valid_during} ->
        if active_at?(valid_during, now), do: :ok, else: {:error, :validation_point_unavailable}

      _missing_or_unavailable ->
        {:error, :validation_point_unavailable}
    end
  end

  defp update_status!(repo, point, status, now) do
    point
    |> Ecto.Changeset.change(
      status: status,
      revision: point.revision + 1,
      updated_at: now
    )
    |> repo.update!()
  end

  defp retire_current_credential(repo, point, now) do
    credential =
      ValidationCredential
      |> where(
        [credential],
        credential.polo_id == ^point.polo_id and
          credential.validation_point_id == ^point.id and
          credential.kind == "api_key"
      )
      |> order_by([credential], desc: credential.version)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> repo.one()

    transition_credential_for_retirement(repo, credential, now)
  end

  defp transition_credential_for_retirement(
         repo,
         %ValidationCredential{status: "active"} = credential,
         now
       ) do
    status = if ended_at_or_before?(credential.valid_during, now), do: "expired", else: "revoked"

    valid_during =
      if status == "revoked" and active_at?(credential.valid_during, now),
        do: close_range(credential.valid_during, now),
        else: credential.valid_during

    updated =
      credential
      |> Ecto.Changeset.change(status: status, valid_during: valid_during)
      |> repo.update!()

    if status == "revoked", do: {:revoked, updated}, else: nil
  end

  defp transition_credential_for_retirement(_repo, _credential, _now), do: nil

  defp complete_transition!(
         repo,
         scope,
         previous,
         point,
         credential_transition,
         request,
         idempotency_id,
         now
       ) do
    result = response_data(previous, point, request, now)

    record_credential_transition!(repo, scope, point, credential_transition, request, now)
    record_transition!(repo, scope, previous, point, request, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "validation_point",
      point.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_credential_transition!(repo, scope, point, {:revoked, credential}, request, now) do
    payload = %{
      "validation_credential_id" => credential.id,
      "validation_point_id" => point.id,
      "credential_kind" => credential.kind,
      "credential_version" => credential.version,
      "source" => "validation_point_retirement",
      "revoked_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "validation_credential",
      aggregate_id: credential.id,
      aggregate_version: 1,
      event_type: "validation_credential.revoked",
      topic: "redemptions.validation_credentials.revoked",
      message_key: credential.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "validation_credential.revoked",
      resource_type: "validation_credential",
      resource_id: credential.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp record_credential_transition!(_repo, _scope, _point, nil, _request, _now), do: :ok

  defp record_transition!(repo, scope, previous, point, request, now) do
    event_name = event_name(request.action)

    payload = %{
      "validation_point_id" => point.id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => point.status,
      "revision" => point.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "validation_point",
      aggregate_id: point.id,
      aggregate_version: point.revision,
      event_type: "validation_point.#{event_name}",
      topic: "redemptions.validation_points.#{event_name}",
      message_key: point.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "validation_point.#{event_name}",
      resource_type: "validation_point",
      resource_id: point.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp event_name("suspend"), do: "suspended"
  defp event_name("reactivate"), do: "reactivated"
  defp event_name("retire"), do: "retired"

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

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "validation_point",
         response_body:
           %{
             "validation_point_id" => point_id,
             "status" => status,
             "revision" => revision
           } = response_body
       })
       when is_binary(point_id) and is_binary(status) and is_integer(revision),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key),
    do: raise("invalid persisted validation point lifecycle response: #{inspect(key)}")

  defp request_hash(scope, point_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      point_id,
      request.action,
      request.reason
    })
  end

  defp reject!(repo, scope, point, request, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "validation_point",
      point.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "validation_point.transition_rejected",
      resource_type: "validation_point",
      resource_id: point.id,
      metadata: %{
        "action" => request.action,
        "current_status" => point.status,
        "reason" => Atom.to_string(reason),
        "operator_reason" => request.reason
      },
      occurred_at: now
    })

    {:denied, reason}
  end

  defp response_data(previous, point, request, now) do
    %{
      "validation_point_id" => point.id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => point.status,
      "revision" => point.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }
  end

  defp active_at?(%Postgrex.Range{lower: lower, upper: :unbound}, now),
    do: DateTime.compare(lower, now) in [:lt, :eq]

  defp active_at?(%Postgrex.Range{lower: lower, upper: upper}, now) do
    DateTime.compare(lower, now) in [:lt, :eq] and DateTime.compare(now, upper) == :lt
  end

  defp ended_at_or_before?(%Postgrex.Range{upper: :unbound}, _now), do: false

  defp ended_at_or_before?(%Postgrex.Range{upper: upper}, now) do
    DateTime.compare(upper, now) in [:lt, :eq]
  end

  defp close_range(range, now), do: %{range | upper: now, upper_inclusive: false}

  defp cast_point_id(point_id) do
    case Ecto.UUID.cast(point_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :validation_point_not_found}
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
