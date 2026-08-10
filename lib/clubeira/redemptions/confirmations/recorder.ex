defmodule Clubeira.Redemptions.Recorder do
  @moduledoc false

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Redemptions.ConfirmedRequest
  alias Clubeira.Redemptions.Eligibility
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Redemptions.RedemptionAttempt
  alias Clubeira.Redemptions.RedemptionEvent
  alias Clubeira.Tenancy.Scope

  @spec accept!(
          module(),
          Scope.t(),
          ConfirmedRequest.t(),
          Eligibility.t(),
          binary(),
          DateTime.t()
        ) :: Redemption.t()
  def accept!(repo, scope, request, eligibility, nonce_hash, now) do
    attempt =
      insert_attempt!(repo, scope, request, eligibility, nonce_hash, now, decision: "accepted")

    redemption =
      %Redemption{
        polo_id: scope.polo_id,
        polo_place_id: eligibility.polo_place_id,
        entitlement_allocation_id: eligibility.allocation_id,
        redemption_attempt_id: attempt.id,
        validation_point_id: eligibility.validation_point_id,
        benefit_package_item_id: eligibility.benefit_package_item_id,
        units: 1,
        redeemed_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    payload = redemption_payload(redemption)

    %RedemptionEvent{
      polo_id: scope.polo_id,
      redemption_id: redemption.id,
      sequence: 1,
      event_type: "confirmed",
      actor_user_id: scope.actor_user_id,
      payload: %{"redemption_attempt_id" => attempt.id, "units" => 1},
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()

    append_delivery!(
      repo,
      scope,
      "redemption",
      redemption.id,
      "redemption.confirmed",
      payload,
      now
    )

    Audit.record_tenant!(repo, scope, %{
      action: "redemption.confirmed",
      resource_type: "redemption",
      resource_id: redemption.id,
      metadata: payload,
      occurred_at: now
    })

    redemption
  end

  @spec deny!(
          module(),
          Scope.t(),
          ConfirmedRequest.t(),
          Eligibility.t(),
          binary(),
          atom(),
          DateTime.t()
        ) :: {String.t(), Ecto.UUID.t()}
  def deny!(repo, scope, request, eligibility, nonce_hash, reason, now) do
    attempt =
      insert_attempt!(repo, scope, request, eligibility, nonce_hash, now,
        decision: "denied",
        reason_code: Atom.to_string(reason)
      )

    payload = attempt_payload(attempt, reason)

    append_delivery!(
      repo,
      scope,
      "redemption_attempt",
      attempt.id,
      "redemption.denied",
      payload,
      now
    )

    Audit.record_tenant!(repo, scope, %{
      action: "redemption.denied",
      resource_type: "redemption_attempt",
      resource_id: attempt.id,
      metadata: payload,
      occurred_at: now
    })

    {"redemption_attempt", attempt.id}
  end

  @spec deny_request!(
          module(),
          Scope.t(),
          ConfirmedRequest.t(),
          Ecto.UUID.t(),
          atom(),
          DateTime.t()
        ) :: {String.t(), Ecto.UUID.t()}
  def deny_request!(repo, scope, request, request_id, reason, now) do
    action = rejection_action(reason)

    payload = %{
      "reason" => Atom.to_string(reason),
      "entitlement_allocation_id" => request.entitlement_allocation_id,
      "validation_point_id" => request.validation_point_id,
      "device_installation_id" => request.device_installation_id
    }

    append_delivery!(repo, scope, "redemption_request", request_id, action, payload, now)

    Audit.record_tenant!(repo, scope, %{
      action: action,
      resource_type: "entitlement_allocation",
      resource_id: request.entitlement_allocation_id,
      metadata: payload,
      occurred_at: now
    })

    {"redemption_request", request_id}
  end

  defp insert_attempt!(repo, scope, request, eligibility, nonce_hash, now, options) do
    context = put_request_id(request.request_context, scope.request_id)

    %RedemptionAttempt{
      polo_id: scope.polo_id,
      polo_place_id: eligibility.polo_place_id,
      validation_point_id: eligibility.validation_point_id,
      entitlement_allocation_id: eligibility.allocation_id,
      benefit_package_item_id: eligibility.benefit_package_item_id,
      requesting_user_id: scope.actor_user_id,
      device_installation_id: eligibility.device_installation_id,
      idempotency_key: request.idempotency_key,
      decision: Keyword.fetch!(options, :decision),
      reason_code: Keyword.get(options, :reason_code),
      request_nonce_hash: nonce_hash,
      risk_score: request.risk_score,
      request_context: context,
      requested_at: now,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp append_delivery!(repo, scope, aggregate_type, aggregate_id, event_type, payload, now) do
    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: aggregate_type,
      aggregate_id: aggregate_id,
      aggregate_version: 1,
      event_type: event_type,
      topic: String.replace(event_type, "redemption.", "redemptions."),
      message_key: aggregate_id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })
  end

  defp redemption_payload(redemption) do
    %{
      "redemption_id" => redemption.id,
      "entitlement_allocation_id" => redemption.entitlement_allocation_id,
      "benefit_package_item_id" => redemption.benefit_package_item_id,
      "polo_place_id" => redemption.polo_place_id,
      "units" => redemption.units,
      "redeemed_at" => DateTime.to_iso8601(redemption.redeemed_at)
    }
  end

  defp attempt_payload(attempt, reason) do
    %{
      "redemption_attempt_id" => attempt.id,
      "entitlement_allocation_id" => attempt.entitlement_allocation_id,
      "polo_place_id" => attempt.polo_place_id,
      "reason" => Atom.to_string(reason),
      "requested_at" => DateTime.to_iso8601(attempt.requested_at)
    }
  end

  defp rejection_action(:nonce_replayed), do: "redemption.nonce_replayed"
  defp rejection_action(_reason), do: "redemption.denied"

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp put_request_id(context, nil), do: context
  defp put_request_id(context, request_id), do: Map.put_new(context, "request_id", request_id)
end
