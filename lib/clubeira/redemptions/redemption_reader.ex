defmodule Clubeira.Redemptions.RedemptionReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Redemptions.RedemptionAttempt
  alias Clubeira.Repo
  alias Clubeira.Reviews.Review
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @spec list(Scope.t(), map()) ::
          {:ok, %{redemptions: [map()], page: map()}}
          | {:error, :actor_required | :invalid_pagination | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :actor_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params) do
      Repo.transact_in_polo(scope, fn repo ->
        {:ok, list_in_scope(repo, scope, pagination)}
      end)
    end
  end

  def list(_scope, _params), do: {:error, :actor_required}

  defp list_in_scope(repo, scope, pagination) do
    query_limit = pagination.limit + 1

    rows =
      Redemption
      |> from(as: :redemption)
      |> join(:inner, [redemption: redemption], attempt in RedemptionAttempt,
        as: :attempt,
        on:
          attempt.id == redemption.redemption_attempt_id and
            attempt.polo_id == redemption.polo_id
      )
      |> join(:inner, [redemption: redemption], polo_place in PoloPlace,
        as: :polo_place,
        on:
          polo_place.id == redemption.polo_place_id and
            polo_place.polo_id == redemption.polo_id
      )
      |> join(:inner, [polo_place: polo_place], place in Place,
        as: :place,
        on: place.id == polo_place.place_id
      )
      |> join(:inner, [redemption: redemption], item in BenefitPackageItem,
        as: :item,
        on:
          item.id == redemption.benefit_package_item_id and
            item.polo_id == redemption.polo_id
      )
      |> join(:inner, [item: item], version in BenefitOfferVersion,
        as: :version,
        on:
          version.id == item.benefit_offer_version_id and
            version.polo_id == item.polo_id
      )
      |> join(:inner, [version: version], offer in BenefitOffer,
        as: :offer,
        on: offer.id == version.benefit_offer_id and offer.polo_id == version.polo_id
      )
      |> join(:left, [place: place], review in Review,
        as: :review,
        on: review.place_id == place.id and review.author_user_id == ^scope.actor_user_id
      )
      |> where([redemption: redemption], redemption.polo_id == ^scope.polo_id)
      |> where([attempt: attempt], attempt.requesting_user_id == ^scope.actor_user_id)
      |> after_attempt(pagination.after)
      |> order_by([attempt: attempt], desc: attempt.requested_at, desc: attempt.id)
      |> select(
        [
          redemption: redemption,
          attempt: attempt,
          place: place,
          version: version,
          offer: offer,
          review: review
        ],
        %{
          id: redemption.id,
          polo_place_id: redemption.polo_place_id,
          units: redemption.units,
          redeemed_at: redemption.redeemed_at,
          cursor_requested_at: attempt.requested_at,
          cursor_attempt_id: attempt.id,
          place: %{
            id: place.id,
            slug: place.slug,
            name: place.name,
            timezone: place.timezone
          },
          benefit: %{
            id: offer.id,
            version_id: version.id,
            kind: offer.benefit_kind,
            title: version.title,
            description: version.description
          },
          review: %{
            id: review.id,
            status: review.status,
            verification_kind: review.verification_kind,
            source_redemption_id: review.source_redemption_id,
            submitted_at: review.inserted_at
          }
        }
      )
      |> limit(^query_limit)
      |> repo.all()
      |> Enum.map(&normalize_review/1)

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      redemptions: page_rows,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp normalize_review(%{review: %{id: nil}} = redemption) do
    %{redemption | review: nil}
  end

  defp normalize_review(redemption), do: redemption

  defp after_attempt(query, nil), do: query

  defp after_attempt(query, %{requested_at: requested_at, id: id}) do
    where(
      query,
      [attempt: attempt],
      attempt.requested_at < ^requested_at or
        (attempt.requested_at == ^requested_at and attempt.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_attempt} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_attempt}}
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
    with {:ok, <<unix_microsecond::signed-64, attempt_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, requested_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, attempt_id} <- Ecto.UUID.load(attempt_id_binary) do
      {:ok, %{requested_at: requested_at, id: attempt_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_redemptions, false), do: nil

  defp next_cursor(redemptions, true) do
    %{cursor_requested_at: requested_at, cursor_attempt_id: id} = List.last(redemptions)
    unix_microsecond = DateTime.to_unix(requested_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
