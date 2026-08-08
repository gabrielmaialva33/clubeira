defmodule Clubeira.Catalog.BenefitOfferReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @statuses ~w(draft active retired)

  @spec list(Scope.t(), map()) ::
          {:ok, %{benefit_offers: [map()], page: map()}}
          | {:error,
             :invalid_benefit_offer_code
             | :invalid_benefit_offer_status
             | :invalid_pagination
             | :invalid_place_id
             | :partner_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, code} <- parse_code(Map.get(params, "code")),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, place_id} <- parse_place_id(Map.get(params, "place_id")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, code, status, place_id, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_admin_required}

  defp list_authorized(repo, scope, code, status, place_id, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_partners, transaction_time(repo)) do
      {:ok, benefit_offer_page(repo, scope, code, status, place_id, pagination)}
    end
  end

  defp benefit_offer_page(repo, scope, code, status, place_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      BenefitOffer
      |> where([offer], offer.polo_id == ^scope.polo_id)
      |> with_code(code)
      |> with_status(status)
      |> with_place(place_id)
      |> after_benefit_offer(pagination.after)
      |> order_by([offer], desc: offer.inserted_at, desc: offer.id)
      |> select([offer], %{
        id: offer.id,
        code: offer.code,
        name: offer.name,
        benefit_kind: offer.benefit_kind,
        status: offer.status,
        recorded_at: offer.inserted_at
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    versions = latest_versions(repo, scope.polo_id, Enum.map(page_rows, & &1.id))

    %{
      benefit_offers:
        Enum.map(page_rows, &Map.put(&1, :latest_version, Map.get(versions, &1.id))),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp latest_versions(_repo, _polo_id, []), do: %{}

  defp latest_versions(repo, polo_id, offer_ids) do
    versions =
      BenefitOfferVersion
      |> where(
        [version],
        version.polo_id == ^polo_id and version.benefit_offer_id in ^offer_ids
      )
      |> distinct([version], version.benefit_offer_id)
      |> order_by([version], asc: version.benefit_offer_id, desc: version.version)
      |> select([version], %{
        id: version.id,
        benefit_offer_id: version.benefit_offer_id,
        version: version.version,
        title: version.title,
        description: version.description,
        terms: version.terms,
        redemption_instructions: version.redemption_instructions,
        percentage_value: version.percentage_value,
        amount_value: version.amount_value,
        currency: version.currency,
        effective_during: version.effective_during,
        status: version.status,
        published_at: version.published_at
      })
      |> repo.all()

    places = places_by_version(repo, polo_id, Enum.map(versions, & &1.id))

    Map.new(versions, fn version ->
      data =
        version
        |> Map.delete(:benefit_offer_id)
        |> Map.put(:places, Map.get(places, version.id, []))

      {version.benefit_offer_id, data}
    end)
  end

  defp places_by_version(_repo, _polo_id, []), do: %{}

  defp places_by_version(repo, polo_id, version_ids) do
    BenefitOfferVersionPlace
    |> join(:inner, [offer_place], polo_place in PoloPlace,
      on:
        polo_place.polo_id == offer_place.polo_id and
          polo_place.id == offer_place.polo_place_id
    )
    |> join(:inner, [_offer_place, polo_place], place in Place,
      on: place.id == polo_place.place_id
    )
    |> where([offer_place], offer_place.polo_id == ^polo_id)
    |> where([offer_place], offer_place.benefit_offer_version_id in ^version_ids)
    |> order_by(
      [offer_place, _polo_place, place],
      asc: offer_place.benefit_offer_version_id,
      asc: place.name,
      asc: offer_place.polo_place_id
    )
    |> select([offer_place, polo_place, place], %{
      benefit_offer_version_id: offer_place.benefit_offer_version_id,
      polo_place_id: offer_place.polo_place_id,
      id: place.id,
      name: place.name,
      slug: place.slug,
      status: place.status,
      participation_status: polo_place.status
    })
    |> repo.all()
    |> Enum.group_by(
      & &1.benefit_offer_version_id,
      &Map.delete(&1, :benefit_offer_version_id)
    )
  end

  defp with_code(query, nil), do: query
  defp with_code(query, code), do: where(query, [offer], offer.code == ^code)

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: where(query, [offer], offer.status == ^status)

  defp with_place(query, nil), do: query

  defp with_place(query, place_id) do
    where(
      query,
      [offer],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM benefit_offer_versions AS offer_version
          JOIN benefit_offer_version_places AS offer_place
            ON offer_place.polo_id = offer_version.polo_id
           AND offer_place.benefit_offer_version_id = offer_version.id
          JOIN polo_places AS polo_place
            ON polo_place.polo_id = offer_place.polo_id
           AND polo_place.id = offer_place.polo_place_id
          WHERE offer_version.polo_id = ?
            AND offer_version.benefit_offer_id = ?
            AND offer_version.version = (
              SELECT max(latest_version.version)
              FROM benefit_offer_versions AS latest_version
              WHERE latest_version.polo_id = offer_version.polo_id
                AND latest_version.benefit_offer_id = offer_version.benefit_offer_id
            )
            AND polo_place.place_id = ?
        )
        """,
        offer.polo_id,
        offer.id,
        type(^place_id, :binary_id)
      )
    )
  end

  defp after_benefit_offer(query, nil), do: query

  defp after_benefit_offer(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [offer],
      offer.inserted_at < ^recorded_at or
        (offer.inserted_at == ^recorded_at and offer.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_offer} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_offer}}
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
    with {:ok, <<unix_microsecond::signed-64, offer_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, offer_id} <- Ecto.UUID.load(offer_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: offer_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_offers, false), do: nil

  defp next_cursor(offers, true) do
    %{recorded_at: recorded_at, id: id} = List.last(offers)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_code(nil), do: {:ok, nil}

  defp parse_code(code) when is_binary(code) do
    normalized = String.trim(code)

    if byte_size(normalized) in 2..80 do
      {:ok, normalized}
    else
      {:error, :invalid_benefit_offer_code}
    end
  end

  defp parse_code(_code), do: {:error, :invalid_benefit_offer_code}

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_benefit_offer_status}

  defp parse_place_id(nil), do: {:ok, nil}

  defp parse_place_id(place_id) when is_binary(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, cast_place_id} -> {:ok, cast_place_id}
      :error -> {:error, :invalid_place_id}
    end
  end

  defp parse_place_id(_place_id), do: {:error, :invalid_place_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
