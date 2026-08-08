defmodule Clubeira.Reviews.ReviewReportReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Polos.Authorization
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewReport
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @statuses ~w(open accepted rejected closed)

  @spec list(Scope.t(), map()) ::
          {:ok, %{reports: [map()], page: map()}}
          | {:error, :moderator_required | :invalid_pagination | :invalid_report_status | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :moderator_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")) do
      Repo.transact_in_polo(scope, &list_authorized(&1, scope, status, pagination))
    end
  end

  def list(_scope, _params), do: {:error, :moderator_required}

  defp list_authorized(repo, scope, status, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :moderate_reviews, transaction_time(repo)) do
      {:ok, report_page(repo, scope, status, pagination)}
    end
  end

  defp report_page(repo, scope, status, pagination) do
    query_limit = pagination.limit + 1

    rows =
      ReviewReport
      |> join(:inner, [report], review in Review, on: review.id == report.review_id)
      |> join(:inner, [_report, review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> join_latest_revision()
      |> join_resolution()
      |> where([_report, _review, redemption], redemption.polo_id == ^scope.polo_id)
      |> where([report], report.status == ^status)
      |> after_report(pagination.after)
      |> order_by([report], desc: report.inserted_at, desc: report.id)
      |> select_report()
      |> limit(^query_limit)
      |> repo.all()

    {reports, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      reports: Enum.map(reports, &present_report/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(reports, has_more)
      }
    }
  end

  defp join_latest_revision(query) do
    latest_revisions =
      from revision in ReviewRevision,
        group_by: revision.review_id,
        select: %{review_id: revision.review_id, revision_number: max(revision.revision_number)}

    query
    |> join(:inner, [_report, review, _redemption], latest in subquery(latest_revisions),
      on: latest.review_id == review.id
    )
    |> join(:inner, [_report, review, _redemption, latest], revision in ReviewRevision,
      on:
        revision.review_id == review.id and
          revision.revision_number == latest.revision_number
    )
  end

  defp join_resolution(query) do
    join(
      query,
      :left,
      [report, _review, _redemption, _latest, _revision],
      action in ModerationAction,
      on: action.review_report_id == report.id
    )
  end

  defp select_report(query) do
    select(query, [report, review, _redemption, _latest, revision, action], %{
      id: report.id,
      review_id: report.review_id,
      reporter_user_id: report.reporter_user_id,
      reason_code: report.reason_code,
      details: report.details,
      status: report.status,
      reported_at: report.inserted_at,
      cursor_at: report.inserted_at,
      resolution: %{
        id: action.id,
        action: action.action,
        actor_user_id: action.actor_user_id,
        reason: action.reason,
        resolved_at: action.occurred_at
      },
      review: %{
        place_id: review.place_id,
        status: review.status,
        revision_number: revision.revision_number,
        rating: revision.rating,
        title: revision.title,
        body: revision.body
      }
    })
  end

  defp present_report(%{resolution: %{id: nil}} = report) do
    report
    |> Map.delete(:cursor_at)
    |> Map.put(:resolution, nil)
  end

  defp present_report(%{resolution: resolution} = report) do
    report
    |> Map.delete(:cursor_at)
    |> Map.put(:resolution, Map.update!(resolution, :action, &public_action/1))
  end

  defp public_action("close_report"), do: "dismiss"
  defp public_action(action), do: action

  defp after_report(query, nil), do: query

  defp after_report(query, %{at: at, id: id}) do
    where(
      query,
      [report],
      report.inserted_at < ^at or (report.inserted_at == ^at and report.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_report} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_report}}
    else
      :error -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_page_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_limit(_limit), do: :error

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, <<unix_microsecond::signed-64, report_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(report_id_binary) do
      {:ok, %{at: at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_reports, false), do: nil

  defp next_cursor(reports, true) do
    report = List.last(reports)
    unix_microsecond = report.cursor_at |> DateTime.to_unix(:microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(report.id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, "open"}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_report_status}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
