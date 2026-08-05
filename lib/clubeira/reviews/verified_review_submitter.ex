defmodule Clubeira.Reviews.VerifiedReviewSubmitter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Redemptions.RedemptionAttempt
  alias Clubeira.Repo
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Reviews.Submission
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "reviews.submit_verified"
  @replay_reasons %{
    "actor_unavailable" => :actor_unavailable,
    "polo_unavailable" => :polo_unavailable,
    "review_already_exists" => :review_already_exists,
    "review_policy_unavailable" => :review_policy_unavailable,
    "reviews_disabled" => :reviews_disabled,
    "source_redemption_unavailable" => :source_redemption_unavailable
  }

  @spec submit(Scope.t(), map()) ::
          {:ok, Clubeira.Reviews.submission()} | {:error, atom() | Ecto.Changeset.t()}
  def submit(%Scope{actor_user_id: nil}, _attributes), do: {:error, :actor_required}

  def submit(%Scope{} = scope, attributes) do
    with {:ok, submission} <- Submission.new(attributes) do
      request_hash = request_hash(scope, submission)

      scope
      |> transact_submission(submission, request_hash)
      |> unwrap_transaction()
    end
  end

  def submit(_scope, _attributes), do: {:error, :actor_required}

  defp transact_submission(scope, submission, request_hash) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      outcome =
        case Idempotency.reserve(
               repo,
               scope,
               @idempotency_scope,
               submission.idempotency_key,
               request_hash,
               now
             ) do
          {:new, idempotency_id} ->
            submit_new(repo, scope, submission, idempotency_id, now)

          {:replay, key} ->
            replay(repo, key)

          {:error, reason} ->
            {:denied, reason}
        end

      {:ok, outcome}
    end)
  end

  defp submit_new(repo, scope, submission, idempotency_id, now) do
    lock_review_identity!(repo, scope.actor_user_id, submission.place_id)

    with :ok <- ensure_actor_active(repo, scope.actor_user_id),
         :ok <- ensure_polo_active(repo, scope.polo_id),
         :ok <- ensure_reviews_enabled(repo, scope.polo_id, now),
         :ok <- ensure_source_redemption(repo, scope, submission),
         :ok <- ensure_review_absent(repo, scope.actor_user_id, submission.place_id) do
      result = insert_review!(repo, scope, submission, now)
      record_submission!(repo, scope, result, now)

      Idempotency.complete!(
        repo,
        idempotency_id,
        "review",
        result.review.id,
        %{"review_id" => result.review.id},
        now
      )

      {:accepted, result}
    else
      {:error, reason} -> reject!(repo, idempotency_id, reason, now)
    end
  end

  defp ensure_actor_active(repo, actor_user_id) do
    query = from user in User, where: user.id == ^actor_user_id, lock: "FOR SHARE"

    case repo.one(query) do
      %User{status: "active", disabled_at: nil} -> :ok
      _unavailable -> {:error, :actor_unavailable}
    end
  end

  defp ensure_polo_active(repo, polo_id) do
    query = from polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE"

    case repo.one(query) do
      %Polo{status: "active"} -> :ok
      _unavailable -> {:error, :polo_unavailable}
    end
  end

  defp ensure_reviews_enabled(repo, polo_id, now) do
    query =
      from policy in PoloPolicyVersion,
        where: policy.polo_id == ^polo_id,
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            policy.effective_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE"

    case repo.one(query) do
      %PoloPolicyVersion{review_policy: policy} when policy in ["open", "verified_only"] ->
        :ok

      %PoloPolicyVersion{review_policy: "disabled"} ->
        {:error, :reviews_disabled}

      _unavailable ->
        {:error, :review_policy_unavailable}
    end
  end

  defp ensure_source_redemption(repo, scope, submission) do
    query =
      Redemption
      |> join(:inner, [redemption], attempt in RedemptionAttempt,
        on:
          attempt.id == redemption.redemption_attempt_id and
            attempt.polo_id == redemption.polo_id
      )
      |> join(:inner, [redemption], polo_place in PoloPlace,
        on:
          polo_place.id == redemption.polo_place_id and
            polo_place.polo_id == redemption.polo_id
      )
      |> where([redemption], redemption.id == ^submission.source_redemption_id)
      |> where([redemption], redemption.polo_id == ^scope.polo_id)
      |> where([_redemption, attempt], attempt.requesting_user_id == ^scope.actor_user_id)
      |> where([_redemption, _attempt, polo_place], polo_place.place_id == ^submission.place_id)
      |> lock("FOR SHARE")
      |> select([redemption], redemption.id)

    if repo.exists?(query), do: :ok, else: {:error, :source_redemption_unavailable}
  end

  defp ensure_review_absent(repo, actor_user_id, place_id) do
    exists? =
      repo.exists?(
        from review in Review,
          where: review.author_user_id == ^actor_user_id and review.place_id == ^place_id
      )

    if exists?, do: {:error, :review_already_exists}, else: :ok
  end

  defp insert_review!(repo, scope, submission, now) do
    review =
      %Review{
        place_id: submission.place_id,
        author_user_id: scope.actor_user_id,
        source_redemption_id: submission.source_redemption_id,
        verification_kind: "verified",
        status: "pending",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    revision =
      %ReviewRevision{
        review_id: review.id,
        author_user_id: scope.actor_user_id,
        revision_number: 1,
        rating: submission.rating,
        title: submission.title,
        body: submission.body,
        inserted_at: now
      }
      |> repo.insert!()

    %{review: review, revision: revision}
  end

  defp record_submission!(repo, scope, result, now) do
    payload = %{
      "review_id" => result.review.id,
      "place_id" => result.review.place_id,
      "source_redemption_id" => result.review.source_redemption_id,
      "verification_kind" => result.review.verification_kind,
      "status" => result.review.status,
      "revision_number" => result.revision.revision_number,
      "rating" => result.revision.rating,
      "submitted_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review",
      aggregate_id: result.review.id,
      aggregate_version: 1,
      event_type: "review.submitted",
      topic: "reviews.submitted",
      message_key: result.review.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "review.submitted",
      resource_type: "review",
      resource_id: result.review.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp replay(repo, %Key{status: "completed", resource_type: "review", resource_id: id}) do
    with %Review{} = review <- repo.get(Review, id),
         %ReviewRevision{} = revision <-
           repo.get_by(ReviewRevision, review_id: id, revision_number: 1) do
      {:accepted, %{review: review, revision: revision}}
    else
      nil -> raise "completed review idempotency key points to missing resource #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted review idempotency response: #{inspect(key)}"
  end

  defp reject!(repo, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now)
    {:denied, reason}
  end

  defp lock_review_identity!(repo, actor_user_id, place_id) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      actor_user_id <> ":" <> place_id
    ])

    :ok
  end

  defp request_hash(scope, submission) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      submission.place_id,
      submission.source_redemption_id,
      submission.rating,
      submission.title,
      submission.body
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
