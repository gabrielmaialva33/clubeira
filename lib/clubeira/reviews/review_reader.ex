defmodule Clubeira.Reviews.ReviewReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @moderation_statuses ~w(pending published rejected hidden removed)

  @spec list_for_moderation(Scope.t(), map()) ::
          {:ok, %{reviews: [map()], page: map()}}
          | {:error, :moderator_required | :invalid_pagination | :invalid_review_status | term()}
  def list_for_moderation(%Scope{actor_user_id: nil}, _params),
    do: {:error, :moderator_required}

  def list_for_moderation(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")) do
      Repo.transact_in_polo(
        scope,
        &list_for_moderation_in_scope(&1, scope, status, pagination)
      )
    end
  end

  def list_for_moderation(_scope, _params), do: {:error, :moderator_required}

  @spec list_public(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{reviews: [map()], page: map()}}
          | {:error, :place_not_found | :invalid_pagination | term()}
  def list_public(%Scope{} = scope, place_id, params) when is_map(params) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, pagination} <- parse_pagination(params) do
      Repo.transact_in_polo(scope, &list_public_in_scope(&1, scope, place_id, pagination))
    end
  end

  def list_public(_scope, _place_id, _params), do: {:error, :place_not_found}

  defp list_for_moderation_in_scope(repo, scope, status, pagination) do
    now = transaction_time(repo)

    case Authorization.authorize(repo, scope, :moderate_reviews, now) do
      :ok -> {:ok, moderation_page(repo, scope, status, pagination)}
      {:error, _reason} = error -> error
    end
  end

  defp list_public_in_scope(repo, scope, place_id, pagination) do
    now = transaction_time(repo)

    if public_place?(repo, scope.polo_id, place_id, now) do
      {:ok, public_page(repo, scope, place_id, pagination)}
    else
      {:error, :place_not_found}
    end
  end

  defp moderation_page(repo, scope, status, pagination) do
    query_limit = pagination.limit + 1

    rows =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> join_latest_revision()
      |> where([review, redemption], redemption.polo_id == ^scope.polo_id)
      |> where([review], review.status == ^status)
      |> after_moderation_review(pagination.after)
      |> order_by([review], desc: review.inserted_at, desc: review.id)
      |> select_moderation_review()
      |> limit(^query_limit)
      |> repo.all()

    page(rows, pagination.limit, :cursor_at)
  end

  defp public_page(repo, scope, place_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> join_latest_revision()
      |> where([review, redemption], redemption.polo_id == ^scope.polo_id)
      |> where([review], review.place_id == ^place_id and review.status == "published")
      |> where([review], not is_nil(review.published_at))
      |> after_public_review(pagination.after)
      |> order_by([review], desc: review.published_at, desc: review.id)
      |> select_public_review()
      |> limit(^query_limit)
      |> repo.all()

    page(rows, pagination.limit, :cursor_at)
  end

  defp join_latest_revision(query) do
    latest_revisions =
      from revision in ReviewRevision,
        group_by: revision.review_id,
        select: %{
          review_id: revision.review_id,
          revision_number: max(revision.revision_number)
        }

    query
    |> join(:inner, [review, _redemption], latest in subquery(latest_revisions),
      on: latest.review_id == review.id
    )
    |> join(:inner, [review, _redemption, latest], revision in ReviewRevision,
      on:
        revision.review_id == review.id and
          revision.revision_number == latest.revision_number
    )
  end

  defp select_moderation_review(query) do
    select(query, [review, _redemption, _latest, revision], %{
      id: review.id,
      place_id: review.place_id,
      author_user_id: review.author_user_id,
      source_redemption_id: review.source_redemption_id,
      verification_kind: review.verification_kind,
      status: review.status,
      revision_number: revision.revision_number,
      rating: revision.rating,
      title: revision.title,
      body: revision.body,
      submitted_at: review.inserted_at,
      published_at: review.published_at,
      rejected_at: review.rejected_at,
      cursor_at: review.inserted_at
    })
  end

  defp select_public_review(query) do
    select(query, [review, _redemption, _latest, revision], %{
      id: review.id,
      place_id: review.place_id,
      verification_kind: review.verification_kind,
      revision_number: revision.revision_number,
      rating: revision.rating,
      title: revision.title,
      body: revision.body,
      published_at: review.published_at,
      cursor_at: review.published_at
    })
  end

  defp public_place?(repo, polo_id, place_id, now) do
    PoloPlace
    |> join(:inner, [polo_place], place in Place, on: place.id == polo_place.place_id)
    |> where([polo_place], polo_place.polo_id == ^polo_id)
    |> where([polo_place], polo_place.place_id == ^place_id and polo_place.status == "active")
    |> where([_polo_place, place], place.status == "active")
    |> where(
      [polo_place],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        polo_place.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> repo.exists?()
  end

  defp after_moderation_review(query, nil), do: query

  defp after_moderation_review(query, %{at: at, id: id}) do
    where(
      query,
      [review],
      review.inserted_at < ^at or (review.inserted_at == ^at and review.id < ^id)
    )
  end

  defp after_public_review(query, nil), do: query

  defp after_public_review(query, %{at: at, id: id}) do
    where(
      query,
      [review],
      review.published_at < ^at or (review.published_at == ^at and review.id < ^id)
    )
  end

  defp page(rows, limit, cursor_field) do
    {reviews, overflow} = Enum.split(rows, limit)
    has_more = overflow != []

    %{
      reviews: Enum.map(reviews, &Map.delete(&1, cursor_field)),
      page: %{
        limit: limit,
        has_more: has_more,
        next_cursor: next_cursor(reviews, has_more, cursor_field)
      }
    }
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_review} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_review}}
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
    with {:ok, <<unix_microsecond::signed-64, review_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, review_id} <- Ecto.UUID.load(review_id_binary) do
      {:ok, %{at: at, id: review_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_reviews, false, _cursor_field), do: nil

  defp next_cursor(reviews, true, cursor_field) do
    review = List.last(reviews)
    unix_microsecond = review |> Map.fetch!(cursor_field) |> DateTime.to_unix(:microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(review.id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, "pending"}

  defp parse_status(status) when status in @moderation_statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_review_status}

  defp cast_place_id(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :place_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
