defmodule Clubeira.Catalog do
  @moduledoc """
  Read operations for the published catalog of a polo.

  A public route may resolve the tenant before authentication, but all tenant
  data is still read inside `Clubeira.Repo.transact_in_polo/3` and filtered to
  currently active, published records.
  """

  import Ecto.Query

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Polos
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @type public_catalog :: %{
          polo: %{id: Ecto.UUID.t(), slug: String.t(), name: String.t(), timezone: String.t()},
          offers: [map()],
          page: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}
        }

  @type fetch_error :: :invalid_pagination | :polo_not_found

  @spec fetch_public(String.t(), map()) :: {:ok, public_catalog()} | {:error, fetch_error()}
  def fetch_public(slug, params \\ %{})

  def fetch_public(slug, params) when is_binary(slug) and is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, route} <- Polos.resolve_route(slug) do
      fetch_public_in_route(route, pagination)
    end
  end

  def fetch_public(_slug, _params), do: {:error, :polo_not_found}

  defp fetch_public_in_route(%PoloRoute{} = route, pagination) do
    scope = Scope.new!(route.polo_id)

    Repo.transact_in_polo(scope, fn repo ->
      case repo.get(Polo, route.polo_id) do
        %Polo{status: "active"} = polo ->
          %{offers: offers, page: page} = list_public_offers(repo, polo.id, pagination)

          {:ok,
           %{
             polo: %{
               id: polo.id,
               slug: route.slug,
               name: polo.name,
               timezone: polo.timezone
             },
             offers: offers,
             page: page
           }}

        %Polo{} ->
          {:error, :polo_not_found}

        nil ->
          {:error, :polo_not_found}
      end
    end)
  end

  defp list_public_offers(repo, polo_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      BenefitOffer
      |> join(:inner, [offer], version in BenefitOfferVersion,
        on:
          version.polo_id == offer.polo_id and
            version.benefit_offer_id == offer.id
      )
      |> where([offer], offer.polo_id == ^polo_id)
      |> where([offer], offer.status == "active")
      |> where([_offer, version], version.status == "published")
      |> where(
        [_offer, version],
        fragment("? @> statement_timestamp()", version.effective_during)
      )
      |> where(
        [_offer, version],
        fragment(
          """
          EXISTS (
            SELECT 1
            FROM benefit_offer_version_places AS offer_place
            JOIN polo_places AS polo_place
              ON polo_place.polo_id = offer_place.polo_id
             AND polo_place.id = offer_place.polo_place_id
            JOIN places AS place
              ON place.id = polo_place.place_id
            WHERE offer_place.polo_id = ?
              AND offer_place.benefit_offer_version_id = ?
              AND polo_place.status = 'active'
              AND polo_place.participation_during @> statement_timestamp()
              AND place.status = 'active'
          )
          """,
          version.polo_id,
          version.id
        )
      )
      |> after_version(pagination.after_id)
      |> order_by([_offer, version], asc: version.id)
      |> select([offer, version], %{
        offer_id: offer.id,
        offer_version_id: version.id,
        version: version.version,
        code: offer.code,
        name: offer.name,
        title: version.title,
        description: version.description,
        terms: version.terms,
        redemption_instructions: version.redemption_instructions,
        benefit_kind: offer.benefit_kind,
        percentage_value: version.percentage_value,
        amount_value: version.amount_value,
        currency: version.currency,
        effective_from: fragment("lower(?)", version.effective_during),
        effective_until: fragment("upper(?)", version.effective_during)
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow_rows} = Enum.split(rows, pagination.limit)
    has_more = overflow_rows != []
    version_ids = Enum.map(page_rows, & &1.offer_version_id)
    places_by_version = list_offer_places(repo, polo_id, version_ids)

    offers =
      Enum.map(page_rows, fn offer ->
        Map.put(offer, :places, Map.get(places_by_version, offer.offer_version_id, []))
      end)

    %{
      offers: offers,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp list_offer_places(_repo, _polo_id, []), do: %{}

  defp list_offer_places(repo, polo_id, version_ids) do
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
    |> where([_offer_place, polo_place], polo_place.status == "active")
    |> where(
      [_offer_place, polo_place],
      fragment("? @> statement_timestamp()", polo_place.participation_during)
    )
    |> where([_offer_place, _polo_place, place], place.status == "active")
    |> order_by(
      [offer_place, polo_place, place],
      asc: offer_place.benefit_offer_version_id,
      asc: place.name,
      asc: polo_place.id
    )
    |> select([offer_place, polo_place, place], %{
      offer_version_id: offer_place.benefit_offer_version_id,
      polo_place_id: polo_place.id,
      place_id: place.id,
      slug: place.slug,
      name: place.name
    })
    |> repo.all()
    |> Enum.group_by(& &1.offer_version_id, &Map.delete(&1, :offer_version_id))
  end

  defp after_version(query, nil), do: query

  defp after_version(query, version_id) do
    where(query, [_offer, version], version.id > ^version_id)
  end

  defp next_cursor(_rows, false), do: nil

  defp next_cursor(rows, true) do
    rows
    |> List.last()
    |> Map.fetch!(:offer_version_id)
    |> Base.url_encode64(padding: false)
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_id} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after_id: after_id}}
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
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, version_id} <- Ecto.UUID.cast(decoded) do
      {:ok, version_id}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error
end
