defmodule Clubeira.Reviews.ReviewReporter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Polo
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewReport
  alias Clubeira.Reviews.ReviewReportRequest
  alias Clubeira.Tenancy.Scope
  alias Plug.Conn.Status

  @idempotency_scope "reviews.report"
  @replay_reasons %{
    "review_already_reported" => :review_already_reported,
    "review_not_found" => :review_not_found,
    "review_not_reportable" => :review_not_reportable,
    "review_report_not_allowed" => :review_report_not_allowed,
    "polo_unavailable" => :polo_unavailable
  }

  @type result :: %{String.t() => term()}

  @spec report(Scope.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def report(%Scope{actor_user_id: nil}, _attributes), do: {:error, :authentication_required}

  def report(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- ReviewReportRequest.new(attributes) do
      scope
      |> transact_report(request)
      |> unwrap_transaction()
    end
  end

  def report(_scope, _attributes), do: {:error, :authentication_required}

  defp transact_report(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      repo
      |> reserve_report(scope, request, now)
      |> transaction_outcome()
    end)
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp reserve_report(repo, scope, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} -> report_new(repo, scope, request, idempotency_id, now)
      {:replay, key} -> replay(key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_new(repo, scope, request, idempotency_id, now) do
    with :ok <- ensure_polo_active(repo, scope.polo_id),
         {:ok, review} <- fetch_reportable_review(repo, scope, request),
         :ok <- authorize_reporter(review, scope.actor_user_id),
         {:ok, report} <- insert_report(repo, scope, review, request, now) do
      complete_report!(repo, scope, report, request, idempotency_id, now)
    else
      {:error, %Ecto.Changeset{}} ->
        reject!(repo, idempotency_id, :review_already_reported, now, :conflict)

      {:error, reason} ->
        reject!(repo, idempotency_id, reason, now, response_status(reason))
    end
  end

  defp ensure_polo_active(repo, polo_id) do
    query = from polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE"

    case repo.one(query) do
      %Polo{status: "active"} -> :ok
      _unavailable -> {:error, :polo_unavailable}
    end
  end

  defp fetch_reportable_review(repo, scope, request) do
    review =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> where([review], review.id == ^request.review_id and review.place_id == ^request.place_id)
      |> where([_review, redemption], redemption.polo_id == ^scope.polo_id)
      |> select([review], review)
      |> lock("FOR SHARE")
      |> repo.one()

    case review do
      nil -> {:error, :review_not_found}
      %Review{status: "published"} = reportable -> {:ok, reportable}
      %Review{} -> {:error, :review_not_reportable}
    end
  end

  defp authorize_reporter(%Review{author_user_id: reporter_id}, reporter_id),
    do: {:error, :review_report_not_allowed}

  defp authorize_reporter(%Review{}, _reporter_id), do: :ok

  defp insert_report(repo, scope, review, request, now) do
    %ReviewReport{
      review_id: review.id,
      reporter_user_id: scope.actor_user_id,
      reason_code: request.reason_code,
      details: request.details,
      status: "open",
      inserted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:review_id, :reporter_user_id],
      name: :review_reports_open_uidx
    )
    |> repo.insert(mode: :savepoint)
  end

  defp complete_report!(repo, scope, report, request, idempotency_id, now) do
    result = response_data(report)

    record_report!(repo, scope, report, request.reason_code, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "review_report",
      report.id,
      result,
      now
    )

    {:accepted, result}
  end

  defp record_report!(repo, scope, report, reason_code, now) do
    payload = %{
      "review_report_id" => report.id,
      "review_id" => report.review_id,
      "reason_code" => reason_code,
      "status" => report.status,
      "reported_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review_report",
      aggregate_id: report.id,
      aggregate_version: 1,
      event_type: "review.reported",
      topic: "reviews.reports.opened",
      message_key: report.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "review.reported",
      resource_type: "review_report",
      resource_id: report.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp response_data(report) do
    %{
      "id" => report.id,
      "review_id" => report.review_id,
      "reason_code" => report.reason_code,
      "status" => report.status,
      "reported_at" => DateTime.to_iso8601(report.inserted_at)
    }
  end

  defp replay(%Key{
         status: "completed",
         resource_type: "review_report",
         response_body: %{"id" => id} = response_body
       })
       when is_binary(id),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key), do: raise("invalid persisted review report response: #{inspect(key)}")

  defp reject!(repo, idempotency_id, reason, now, response_status) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now,
      response_status: Status.code(response_status)
    )

    {:denied, reason}
  end

  defp response_status(:review_not_found), do: :not_found
  defp response_status(:review_already_reported), do: :conflict
  defp response_status(_reason), do: :unprocessable_entity

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.place_id,
      request.review_id,
      request.reason_code,
      request.details
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
