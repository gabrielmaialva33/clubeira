defmodule Clubeira.Subscriptions.ProductOfferingLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingLifecycleRequest
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "subscriptions.transition_product_offering"
  @replay_reasons %{
    "invalid_product_offering_transition" => :invalid_product_offering_transition
  }

  @type result :: %{String.t() => term()}

  @spec transition(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(%Scope{actor_user_id: nil}, _offering_id, _attributes),
    do: {:error, :partner_admin_required}

  def transition(%Scope{} = scope, offering_id, attributes) when is_map(attributes) do
    with {:ok, offering_id} <- cast_offering_id(offering_id),
         {:ok, request} <- ProductOfferingLifecycleRequest.new(attributes) do
      scope
      |> transact_transition(offering_id, request)
      |> unwrap_transaction()
    end
  end

  def transition(_scope, _offering_id, _attributes),
    do: {:error, :partner_admin_required}

  defp transact_transition(scope, offering_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        repo
        |> reserve_transition(scope, offering_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_transition(repo, scope, offering_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, offering_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        transition_new(repo, scope, offering_id, request, idempotency_id)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition_new(repo, scope, offering_id, request, idempotency_id) do
    with {:ok, offering} <- lock_offering(repo, scope, offering_id) do
      now = transaction_time(repo)

      case transition_offering(repo, offering, request.action, now) do
        {:ok, updated} ->
          complete_transition!(repo, scope, offering, updated, request, idempotency_id, now)

        {:error, reason} ->
          reject!(repo, scope, offering, request, idempotency_id, reason, now)
      end
    end
  end

  defp lock_offering(repo, scope, offering_id) do
    offering =
      ProductOffering
      |> where([offering], offering.id == ^offering_id and offering.polo_id == ^scope.polo_id)
      |> lock("FOR UPDATE")
      |> repo.one()

    case offering do
      %ProductOffering{} -> {:ok, offering}
      nil -> {:error, :product_offering_not_found}
    end
  end

  defp transition_offering(repo, %ProductOffering{status: "active"} = offering, "pause", now) do
    {:ok, update_status!(repo, offering, "paused", now)}
  end

  defp transition_offering(_repo, _offering, _action, _now),
    do: {:error, :invalid_product_offering_transition}

  defp update_status!(repo, offering, status, now) do
    offering
    |> Ecto.Changeset.change(
      status: status,
      revision: offering.revision + 1,
      updated_at: now
    )
    |> repo.update!()
  end

  defp complete_transition!(repo, scope, previous, offering, request, idempotency_id, now) do
    result = response_data(previous, offering, request, now)

    record_transition!(repo, scope, previous, offering, request, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "product_offering",
      offering.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp record_transition!(repo, scope, previous, offering, request, now) do
    event_name = "paused"

    payload = %{
      "product_offering_id" => offering.id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => offering.status,
      "revision" => offering.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "product_offering",
      aggregate_id: offering.id,
      aggregate_version: offering.revision,
      event_type: "product_offering.#{event_name}",
      topic: "subscriptions.product_offerings.#{event_name}",
      message_key: offering.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "product_offering.#{event_name}",
      resource_type: "product_offering",
      resource_id: offering.id,
      metadata: Map.put(payload, "reason", request.reason),
      occurred_at: now
    })
  end

  defp reject!(repo, scope, offering, request, idempotency_id, reason, now) do
    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "product_offering",
      offering.id,
      now,
      response_status: 409
    )

    Audit.record_tenant!(repo, scope, %{
      action: "product_offering.transition_rejected",
      resource_type: "product_offering",
      resource_id: offering.id,
      metadata: %{
        "action" => request.action,
        "current_status" => offering.status,
        "reason" => Atom.to_string(reason),
        "operator_reason" => request.reason
      },
      occurred_at: now
    })

    {:denied, reason}
  end

  defp response_data(previous, offering, request, now) do
    %{
      "product_offering_id" => offering.id,
      "action" => request.action,
      "previous_status" => previous.status,
      "status" => offering.status,
      "revision" => offering.revision,
      "transitioned_at" => DateTime.to_iso8601(now)
    }
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "product_offering",
         response_body:
           %{
             "product_offering_id" => offering_id,
             "status" => status,
             "revision" => revision
           } = response_body
       })
       when is_binary(offering_id) and is_binary(status) and is_integer(revision),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key),
    do: raise("invalid persisted product offering lifecycle response: #{inspect(key)}")

  defp request_hash(scope, offering_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      offering_id,
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

  defp cast_offering_id(offering_id) do
    case Ecto.UUID.cast(offering_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :product_offering_not_found}
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
