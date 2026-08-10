defmodule Clubeira.Directory.PlaceParticipationLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceParticipationLifecycleRequest
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "directory.transition_place_participation"
  @replay_reasons %{
    "invalid_place_participation_transition" => :invalid_place_participation_transition,
    "place_unavailable" => :place_unavailable
  }

  @type result :: %{String.t() => term()}

  @spec transition(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(%Scope{actor_user_id: nil}, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  def transition(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, request} <- PlaceParticipationLifecycleRequest.new(attributes) do
      scope
      |> transact_transition(place_id, request)
      |> unwrap_transaction()
    end
  end

  def transition(_scope, _place_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_transition(scope, place_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        repo
        |> reserve_transition(scope, place_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_transition(repo, scope, place_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, place_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        transition_new(repo, scope, place_id, request, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition_new(repo, scope, place_id, request, idempotency_id) do
    with {:ok, participation} <- lock_current_participation(repo, scope, place_id) do
      now = transaction_time(repo)

      case transition_participation(repo, participation, request.action, now) do
        {:ok, updated} ->
          complete_transition!(
            repo,
            scope,
            participation,
            updated,
            request,
            idempotency_id,
            now
          )

        {:error, reason} ->
          reject!(repo, scope, participation, request, idempotency_id, reason, now)
      end
    end
  end

  defp lock_current_participation(repo, scope, place_id) do
    current =
      PoloPlace
      |> where(
        [participation],
        participation.polo_id == ^scope.polo_id and participation.place_id == ^place_id
      )
      |> where(
        [participation],
        fragment("? @> statement_timestamp()", participation.participation_during)
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    participation = current || lock_retired_participation(repo, scope, place_id)

    case participation do
      %PoloPlace{} -> {:ok, participation}
      nil -> {:error, :place_not_found}
    end
  end

  defp lock_retired_participation(repo, scope, place_id) do
    PoloPlace
    |> where(
      [participation],
      participation.polo_id == ^scope.polo_id and participation.place_id == ^place_id and
        participation.status == "retired"
    )
    |> order_by([participation], desc: participation.updated_at, desc: participation.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp transition_participation(
         repo,
         %PoloPlace{status: "active"} = participation,
         "suspend",
         now
       ) do
    {:ok, update_status!(repo, participation, "suspended", now)}
  end

  defp transition_participation(
         repo,
         %PoloPlace{status: "suspended"} = participation,
         "reactivate",
         now
       ) do
    with :ok <- ensure_place_active(repo, participation.place_id) do
      {:ok, update_status!(repo, participation, "active", now)}
    end
  end

  defp transition_participation(
         repo,
         %PoloPlace{status: status} = participation,
         "retire",
         now
       )
       when status in ["active", "suspended"] do
    {:ok, retire!(repo, participation, now)}
  end

  defp transition_participation(_repo, _participation, _action, _now),
    do: {:error, :invalid_place_participation_transition}

  defp ensure_place_active(repo, place_id) do
    active? =
      Place
      |> where([place], place.id == ^place_id and place.status == "active")
      |> lock("FOR SHARE")
      |> repo.exists?()

    if active?, do: :ok, else: {:error, :place_unavailable}
  end

  defp update_status!(repo, participation, status, now) do
    participation
    |> Ecto.Changeset.change(
      status: status,
      revision: participation.revision + 1,
      updated_at: now
    )
    |> repo.update!()
  end

  defp retire!(repo, participation, now) do
    %Postgrex.Range{} = current_period = participation.participation_during

    participation_during = %Postgrex.Range{
      current_period
      | upper: now,
        upper_inclusive: false
    }

    participation
    |> Ecto.Changeset.change(
      status: "retired",
      participation_during: participation_during,
      revision: participation.revision + 1,
      updated_at: now
    )
    |> repo.update!()
  end

  defp complete_transition!(repo, scope, previous, participation, request, idempotency_id, now) do
    result = response_data(previous, participation, request, now)

    record_transition!(repo, scope, previous, participation, request, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "polo_place",
      participation.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_transition!(repo, scope, previous, participation, request, now) do
    event_name = event_name(request.action)

    payload = %{
      "polo_place_id" => participation.id,
      "place_id" => participation.place_id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => participation.status,
      "revision" => participation.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "polo_place",
      aggregate_id: participation.id,
      aggregate_version: participation.revision,
      event_type: "polo_place.#{event_name}",
      topic: "directory.polo_places.#{event_name}",
      message_key: participation.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "polo_place.#{event_name}",
      resource_type: "polo_place",
      resource_id: participation.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp event_name("suspend"), do: "suspended"
  defp event_name("reactivate"), do: "reactivated"
  defp event_name("retire"), do: "retired"

  defp reject!(repo, scope, participation, request, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "polo_place",
      participation.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "polo_place.transition_rejected",
      resource_type: "polo_place",
      resource_id: participation.id,
      metadata: %{
        "action" => request.action,
        "current_status" => participation.status,
        "reason" => Atom.to_string(reason),
        "operator_reason" => request.reason
      },
      occurred_at: now
    })

    {:denied, reason}
  end

  defp response_data(previous, participation, request, now) do
    %{
      "polo_place_id" => participation.id,
      "place_id" => participation.place_id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => participation.status,
      "revision" => participation.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "polo_place",
         response_body:
           %{
             "polo_place_id" => participation_id,
             "status" => status,
             "revision" => revision
           } = response_body
       })
       when is_binary(participation_id) and is_binary(status) and is_integer(revision),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key),
    do: raise("invalid persisted place participation lifecycle response: #{inspect(key)}")

  defp request_hash(scope, place_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      place_id,
      request.action,
      request.reason
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

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
