defmodule Clubeira.Reviews.ReviewModerator do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.ModerationRequest
  alias Clubeira.Reviews.Review
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "reviews.moderate"
  @replay_reasons %{
    "invalid_review_transition" => :invalid_review_transition,
    "review_not_found" => :review_not_found
  }

  @spec moderate(Scope.t(), map()) ::
          {:ok, %{review: Review.t(), action: ModerationAction.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def moderate(%Scope{actor_user_id: nil}, _attributes), do: {:error, :moderator_required}

  def moderate(%Scope{} = scope, attributes) do
    with {:ok, request} <- ModerationRequest.new(attributes) do
      scope
      |> transact_moderation(request)
      |> unwrap_transaction()
    end
  end

  def moderate(_scope, _attributes), do: {:error, :moderator_required}

  defp transact_moderation(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      case Authorization.authorize(repo, scope, :moderate_reviews, now) do
        :ok -> {:ok, reserve_moderation(repo, scope, request, now)}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp reserve_moderation(repo, scope, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} -> moderate_new(repo, scope, request, idempotency_id, now)
      {:replay, key} -> replay(repo, key)
      {:error, reason} -> {:denied, reason}
    end
  end

  defp moderate_new(repo, scope, request, idempotency_id, now) do
    case fetch_pending_review(repo, scope, request.review_id) do
      {:ok, review} -> moderate_review!(repo, scope, review, request, idempotency_id, now)
      {:error, reason} -> reject!(repo, idempotency_id, reason, now)
    end
  end

  defp moderate_review!(repo, scope, review, request, idempotency_id, now) do
    updated_review = transition_review!(repo, review, request.action, now)

    action =
      %ModerationAction{
        review_id: review.id,
        actor_user_id: scope.actor_user_id,
        action: request.action,
        reason: request.reason,
        metadata: request_metadata(scope),
        occurred_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    record_moderation!(repo, scope, updated_review, action, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "moderation_action",
      action.id,
      %{"moderation_action_id" => action.id, "review_id" => review.id},
      now
    )

    {:accepted, %{review: updated_review, action: action}}
  end

  defp fetch_pending_review(repo, scope, review_id) do
    query =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> where([review], review.id == ^review_id)
      |> where([_review, redemption], redemption.polo_id == ^scope.polo_id)
      |> select([review], review)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      nil -> {:error, :review_not_found}
      %Review{status: "pending"} = review -> {:ok, review}
      %Review{} -> {:error, :invalid_review_transition}
    end
  end

  defp transition_review!(repo, review, "publish", now) do
    review
    |> Ecto.Changeset.change(
      status: "published",
      published_at: now,
      rejected_at: nil,
      updated_at: now
    )
    |> repo.update!()
  end

  defp transition_review!(repo, review, "reject", now) do
    review
    |> Ecto.Changeset.change(
      status: "rejected",
      published_at: nil,
      rejected_at: now,
      updated_at: now
    )
    |> repo.update!()
  end

  defp record_moderation!(repo, scope, review, action, now) do
    event_name = "review.#{review.status}"
    topic = "reviews.#{review.status}"

    payload = %{
      "review_id" => review.id,
      "place_id" => review.place_id,
      "moderation_action_id" => action.id,
      "status" => review.status,
      "moderated_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review",
      aggregate_id: review.id,
      aggregate_version: 2,
      event_type: event_name,
      topic: topic,
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

  defp replay(
         repo,
         %Key{status: "completed", resource_type: "moderation_action", resource_id: id}
       ) do
    with %ModerationAction{} = action <- repo.get(ModerationAction, id),
         %Review{} = review <- repo.get(Review, action.review_id) do
      {:accepted, %{review: review, action: action}}
    else
      nil -> raise "completed review moderation key points to missing resource #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted review moderation response: #{inspect(key)}"
  end

  defp reject!(repo, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now)
    {:denied, reason}
  end

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.review_id,
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
