defmodule Clubeira.Reviews.PartnerReviewReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.PartnerPlaceAccess
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewResponse
  alias Clubeira.Reviews.ReviewResponseRevision
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @type result :: %{
          reviews: [map()],
          page: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}
        }

  @spec list(Scope.t(), map()) ::
          {:ok, result()}
          | {:error, :invalid_pagination | :partner_access_required | :place_not_found | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_access_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, place_id} <- parse_place_id(Map.get(params, "place_id")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, place_id, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_access_required}

  @spec get(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :partner_access_required | :review_not_found | term()}
  def get(%Scope{actor_user_id: nil}, _review_id), do: {:error, :partner_access_required}

  def get(%Scope{} = scope, review_id) do
    with {:ok, review_id} <- cast_review_id(review_id) do
      Repo.transact_in_polo(scope, &get_authorized(&1, scope, review_id))
    end
  end

  def get(_scope, _review_id), do: {:error, :partner_access_required}

  defp list_authorized(repo, scope, place_id, pagination) do
    now = transaction_time(repo)
    assigned_places = assigned_places_query(scope, now)

    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now),
         :ok <- ensure_assigned_place(repo, assigned_places, place_id) do
      {:ok, review_page(repo, scope, assigned_places, place_id, pagination)}
    end
  end

  defp get_authorized(repo, scope, review_id) do
    now = transaction_time(repo)
    assigned_places = assigned_places_query(scope, now)

    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now),
         :ok <- ensure_assigned_place(repo, assigned_places, nil) do
      review =
        scope
        |> review_query(assigned_places, nil)
        |> where([review: review], review.id == ^review_id)
        |> select_review()
        |> repo.one()

      if review, do: {:ok, review_data(review)}, else: {:error, :review_not_found}
    end
  end

  defp assigned_places_query(scope, now) do
    affiliations = PartnerPlaceAccess.active_place_organizations_query(scope, now)

    PoloPlace
    |> join(:inner, [participation], place in Place, on: place.id == participation.place_id)
    |> join(:inner, [_participation, place], affiliation in subquery(affiliations),
      on: affiliation.place_id == place.id
    )
    |> where([participation], participation.polo_id == ^scope.polo_id)
    |> where([participation], participation.status == "active")
    |> where([_participation, place], place.status == "active")
    |> where(
      [participation],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        participation.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> select([_participation, place, affiliation], %{
      place_id: place.id,
      organization_id: affiliation.organization_id
    })
  end

  defp ensure_assigned_place(repo, assigned_places, nil) do
    if repo.exists?(assigned_places), do: :ok, else: {:error, :partner_access_required}
  end

  defp ensure_assigned_place(repo, assigned_places, place_id) do
    if assigned_places |> where([row], row.place_id == ^place_id) |> repo.exists?() do
      :ok
    else
      {:error, :place_not_found}
    end
  end

  defp review_page(repo, scope, assigned_places, place_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      scope
      |> review_query(assigned_places, place_id)
      |> after_review(pagination.after)
      |> order_by([review: review], desc: review.published_at, desc: review.id)
      |> select_review()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      reviews: Enum.map(page_rows, &review_data/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp review_query(scope, assigned_places, place_id) do
    Review
    |> from(as: :review)
    |> join(:inner, [review: review], redemption in Redemption,
      as: :redemption,
      on: redemption.id == review.source_redemption_id
    )
    |> join(:inner, [review: review], place in Place,
      as: :place,
      on: place.id == review.place_id
    )
    |> join(:inner, [place: place], assignment in subquery(assigned_places),
      as: :assignment,
      on: assignment.place_id == place.id
    )
    |> join(:inner, [assignment: assignment], organization in Organization,
      as: :organization,
      on: organization.id == assignment.organization_id
    )
    |> join_latest_review_revision()
    |> join_partner_response()
    |> where(
      [review: review, redemption: redemption],
      redemption.polo_id == ^scope.polo_id and review.status == "published" and
        not is_nil(review.published_at)
    )
    |> with_place(place_id)
  end

  defp join_latest_review_revision(query) do
    latest =
      from revision in ReviewRevision,
        group_by: revision.review_id,
        select: %{review_id: revision.review_id, revision_number: max(revision.revision_number)}

    query
    |> join(:inner, [review: review], latest in subquery(latest),
      as: :latest_review,
      on: latest.review_id == review.id
    )
    |> join(:inner, [review: review, latest_review: latest], revision in ReviewRevision,
      as: :review_revision,
      on:
        revision.review_id == review.id and
          revision.revision_number == latest.revision_number
    )
  end

  defp join_partner_response(query) do
    latest =
      from revision in ReviewResponseRevision,
        group_by: revision.review_response_id,
        select: %{
          review_response_id: revision.review_response_id,
          revision_number: max(revision.revision_number)
        }

    query
    |> join(:left, [review: review, assignment: assignment], response in ReviewResponse,
      as: :response,
      on:
        response.review_id == review.id and
          response.organization_id == assignment.organization_id
    )
    |> join(:left, [response: response], latest in subquery(latest),
      as: :latest_response,
      on: latest.review_response_id == response.id
    )
    |> join(
      :left,
      [response: response, latest_response: latest],
      revision in ReviewResponseRevision,
      as: :response_revision,
      on:
        revision.review_response_id == response.id and
          revision.revision_number == latest.revision_number
    )
  end

  defp select_review(query) do
    select(
      query,
      [
        review: review,
        place: place,
        organization: organization,
        review_revision: revision,
        response: response,
        response_revision: response_revision
      ],
      %{
        id: review.id,
        verification_kind: review.verification_kind,
        revision_number: revision.revision_number,
        rating: revision.rating,
        title: revision.title,
        body: revision.body,
        published_at: review.published_at,
        cursor_at: review.published_at,
        place_id: place.id,
        place_name: place.name,
        place_slug: place.slug,
        organization_id: organization.id,
        organization_name: coalesce(organization.trade_name, organization.legal_name),
        response_id: response.id,
        response_status: response.status,
        response_published_at: response.published_at,
        response_updated_at: response.updated_at,
        response_revision_number: response_revision.revision_number,
        response_body: response_revision.body
      }
    )
  end

  defp review_data(row) do
    %{
      id: row.id,
      verification_kind: row.verification_kind,
      revision_number: row.revision_number,
      rating: row.rating,
      title: row.title,
      body: row.body,
      published_at: row.published_at,
      place: %{id: row.place_id, name: row.place_name, slug: row.place_slug},
      response: response_data(row)
    }
  end

  defp response_data(%{response_id: nil}), do: nil

  defp response_data(row) do
    %{
      id: row.response_id,
      organization: %{id: row.organization_id, name: row.organization_name},
      status: row.response_status,
      revision_number: row.response_revision_number,
      body: row.response_body,
      published_at: row.response_published_at,
      updated_at: row.response_updated_at
    }
  end

  defp with_place(query, nil), do: query

  defp with_place(query, place_id),
    do: where(query, [review: review], review.place_id == ^place_id)

  defp after_review(query, nil), do: query

  defp after_review(query, %{at: at, id: id}) do
    where(
      query,
      [review: review],
      review.published_at < ^at or (review.published_at == ^at and review.id < ^id)
    )
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

  defp parse_place_id(nil), do: {:ok, nil}

  defp parse_place_id(place_id) when is_binary(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, place_id} -> {:ok, place_id}
      :error -> {:error, :place_not_found}
    end
  end

  defp parse_place_id(_place_id), do: {:error, :place_not_found}

  defp cast_review_id(review_id) do
    case Ecto.UUID.cast(review_id) do
      {:ok, review_id} -> {:ok, review_id}
      :error -> {:error, :review_not_found}
    end
  end

  defp next_cursor(_reviews, false), do: nil

  defp next_cursor(reviews, true) do
    %{cursor_at: at, id: id} = List.last(reviews)
    unix_microsecond = DateTime.to_unix(at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
