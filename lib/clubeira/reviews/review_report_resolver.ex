defmodule Clubeira.Reviews.ReviewReportResolver do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewReport
  alias Clubeira.Reviews.ReviewReportResolutionRequest
  alias Clubeira.Tenancy.Scope
  alias Plug.Conn.Status

  @idempotency_scope "reviews.resolve_report"
  @replay_reasons %{
    "invalid_review_report_transition" => :invalid_review_report_transition,
    "review_report_not_found" => :review_report_not_found
  }

  @type result :: %{String.t() => term()}

  @spec resolve(Scope.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def resolve(%Scope{actor_user_id: nil}, _attributes), do: {:error, :moderator_required}

  def resolve(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- ReviewReportResolutionRequest.new(attributes) do
      scope
      |> transact_resolution(request)
      |> unwrap_transaction()
    end
  end

  def resolve(_scope, _attributes), do: {:error, :moderator_required}

  defp transact_resolution(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      case Authorization.authorize(repo, scope, :moderate_reviews, now) do
        :ok -> {:ok, reserve_resolution(repo, scope, request, now)}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp reserve_resolution(repo, scope, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} -> resolve_new(repo, scope, request, idempotency_id, now)
      {:replay, key} -> replay(key)
      {:error, reason} -> {:denied, reason}
    end
  end

  defp resolve_new(repo, scope, request, idempotency_id, now) do
    case fetch_open_report(repo, scope, request.review_report_id) do
      {:ok, report, review} ->
        resolve_report!(repo, scope, report, review, request, idempotency_id, now)

      {:error, reason} ->
        reject!(repo, idempotency_id, reason, now, response_status(reason))
    end
  end

  defp fetch_open_report(repo, scope, report_id) do
    result =
      ReviewReport
      |> join(:inner, [report], review in Review, on: review.id == report.review_id)
      |> join(:inner, [_report, review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> where([report], report.id == ^report_id)
      |> where([_report, _review, redemption], redemption.polo_id == ^scope.polo_id)
      |> select([report, review], {report, review})
      |> lock("FOR UPDATE")
      |> repo.one()

    case result do
      nil -> {:error, :review_report_not_found}
      {%ReviewReport{status: "open"} = report, %Review{} = review} -> {:ok, report, review}
      {%ReviewReport{}, %Review{}} -> {:error, :invalid_review_report_transition}
    end
  end

  defp resolve_report!(repo, scope, report, review, request, idempotency_id, now) do
    {report_status, persisted_action} = report_transition(request.action)
    updated_review = transition_review!(repo, review, request.action, now)

    updated_report =
      report
      |> Ecto.Changeset.change(status: report_status)
      |> repo.update!()

    action =
      %ModerationAction{
        review_id: review.id,
        review_report_id: report.id,
        actor_user_id: scope.actor_user_id,
        action: persisted_action,
        reason: request.reason,
        metadata: request_metadata(scope),
        occurred_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    record_report_resolution!(repo, scope, updated_report, updated_review, action, request, now)
    record_review_transition!(repo, scope, review, updated_review, action, now)

    result = response_data(updated_report, updated_review, action, request.action)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "moderation_action",
      action.id,
      result,
      now
    )

    {:accepted, result}
  end

  defp report_transition("dismiss"), do: {"rejected", "close_report"}
  defp report_transition(action) when action in ["hide", "remove"], do: {"accepted", action}

  defp transition_review!(_repo, review, "dismiss", _now), do: review

  defp transition_review!(repo, %Review{status: "published"} = review, "hide", now),
    do: update_review_status!(repo, review, "hidden", now)

  defp transition_review!(_repo, %Review{status: status} = review, "hide", _now)
       when status in ["hidden", "removed"],
       do: review

  defp transition_review!(repo, %Review{status: status} = review, "remove", now)
       when status in ["published", "hidden"],
       do: update_review_status!(repo, review, "removed", now)

  defp transition_review!(_repo, %Review{status: "removed"} = review, "remove", _now), do: review

  defp update_review_status!(repo, review, status, now) do
    review
    |> Ecto.Changeset.change(status: status, updated_at: now)
    |> repo.update!()
  end

  defp record_report_resolution!(repo, scope, report, review, action, request, now) do
    event_status = report.status
    event_name = "review.report.#{event_status}"

    payload = %{
      "review_report_id" => report.id,
      "review_id" => review.id,
      "moderation_action_id" => action.id,
      "action" => request.action,
      "report_status" => report.status,
      "review_status" => review.status,
      "resolved_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review_report",
      aggregate_id: report.id,
      aggregate_version: 2,
      event_type: event_name,
      topic: "reviews.reports.#{event_status}",
      message_key: report.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: event_name,
      resource_type: "review_report",
      resource_id: report.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp record_review_transition!(_repo, _scope, previous, current, _action, _now)
       when previous.status == current.status,
       do: :ok

  defp record_review_transition!(repo, scope, _previous, review, action, now) do
    event_name = "review.#{review.status}"

    payload = %{
      "review_id" => review.id,
      "place_id" => review.place_id,
      "review_report_id" => action.review_report_id,
      "moderation_action_id" => action.id,
      "status" => review.status,
      "moderated_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review",
      aggregate_id: review.id,
      aggregate_version: next_review_version(repo, scope, review.id),
      event_type: event_name,
      topic: "reviews.#{review.status}",
      message_key: review.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: event_name,
      resource_type: "review",
      resource_id: review.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp next_review_version(repo, scope, review_id) do
    DomainEvent
    |> where(
      [event],
      event.polo_id == ^scope.polo_id and event.aggregate_type == "review" and
        event.aggregate_id == ^review_id
    )
    |> select([event], coalesce(max(event.aggregate_version), 0) + 1)
    |> repo.one!()
  end

  defp response_data(report, review, action, public_action) do
    %{
      "id" => action.id,
      "review_report_id" => report.id,
      "review_id" => review.id,
      "action" => public_action,
      "report_status" => report.status,
      "review_status" => review.status,
      "resolved_at" => DateTime.to_iso8601(action.occurred_at)
    }
  end

  defp replay(%Key{
         status: "completed",
         resource_type: "moderation_action",
         response_body: %{"id" => id} = response_body
       })
       when is_binary(id),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key), do: raise("invalid persisted review report resolution: #{inspect(key)}")

  defp reject!(repo, idempotency_id, reason, now, response_status) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now,
      response_status: Status.code(response_status)
    )

    {:denied, reason}
  end

  defp response_status(:review_report_not_found), do: :not_found
  defp response_status(:invalid_review_report_transition), do: :conflict

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.review_report_id,
      request.action,
      request.reason
    })
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
