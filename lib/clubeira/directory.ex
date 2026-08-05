defmodule Clubeira.Directory do
  @moduledoc """
  Public discovery of active commercial places participating in a polo.

  Places, brands and organizations are global identities. A public listing is
  still entered through `polo_places` inside the routed polo's RLS boundary.
  """

  import Ecto.Query

  alias Clubeira.Directory.Address
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceBrand
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Polos
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @type public_directory :: %{
          polo: %{id: Ecto.UUID.t(), slug: String.t(), name: String.t(), timezone: String.t()},
          places: [map()],
          page: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}
        }

  @spec fetch_public(String.t(), map()) ::
          {:ok, public_directory()} | {:error, :invalid_pagination | :polo_not_found}
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
          %{places: places, page: page} = list_places(repo, polo.id, pagination)

          {:ok,
           %{
             polo: %{id: polo.id, slug: route.slug, name: polo.name, timezone: polo.timezone},
             places: places,
             page: page
           }}

        %Polo{} ->
          {:error, :polo_not_found}

        nil ->
          {:error, :polo_not_found}
      end
    end)
  end

  defp list_places(repo, polo_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      PoloPlace
      |> from(as: :polo_place)
      |> join(:inner, [polo_place: polo_place], place in Place,
        as: :place,
        on: place.id == polo_place.place_id
      )
      |> join(:inner, [place: place], address in Address,
        as: :address,
        on: address.id == place.address_id and address.city_id == place.city_id
      )
      |> join(:inner, [place: place], city in City,
        as: :city,
        on: city.id == place.city_id
      )
      |> where([polo_place: polo_place], polo_place.polo_id == ^polo_id)
      |> where([polo_place: polo_place], polo_place.status == "active")
      |> where(
        [polo_place: polo_place],
        fragment("? @> statement_timestamp()", polo_place.participation_during)
      )
      |> where([place: place], place.status == "active")
      |> where([city: city], city.status == "active")
      |> after_place(pagination.after_id)
      |> order_by([place: place], asc: place.id)
      |> select([polo_place: polo_place, place: place, address: address, city: city], %{
        polo_place_id: polo_place.id,
        place_id: place.id,
        slug: place.slug,
        name: place.name,
        timezone: place.timezone,
        address: %{
          street: address.street,
          number: address.number,
          complement: address.complement,
          district: address.district,
          postal_code: address.postal_code,
          latitude: address.latitude,
          longitude: address.longitude,
          city: %{
            id: city.id,
            name: city.name,
            country_code: city.country_code,
            subdivision_code: city.subdivision_code,
            timezone: city.timezone
          }
        }
      })
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    place_ids = Enum.map(page_rows, & &1.place_id)
    brands_by_place = list_brands(repo, place_ids)
    operators_by_place = list_operators(repo, place_ids)

    places =
      Enum.map(page_rows, fn place ->
        place
        |> Map.put(:brands, Map.get(brands_by_place, place.place_id, []))
        |> Map.put(:operators, Map.get(operators_by_place, place.place_id, []))
      end)

    %{
      places: places,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp after_place(query, nil), do: query

  defp after_place(query, place_id) do
    where(query, [place: place], place.id > ^place_id)
  end

  defp list_brands(_repo, []), do: %{}

  defp list_brands(repo, place_ids) do
    PlaceBrand
    |> join(:inner, [place_brand], brand in Brand, on: brand.id == place_brand.brand_id)
    |> where([place_brand], place_brand.place_id in ^place_ids)
    |> where(
      [place_brand],
      fragment("? @> statement_timestamp()", place_brand.valid_during)
    )
    |> where([_place_brand, brand], brand.status == "active")
    |> order_by([place_brand, brand], asc: place_brand.place_id, asc: brand.name, asc: brand.id)
    |> select([place_brand, brand], %{
      place_id: place_brand.place_id,
      id: brand.id,
      slug: brand.slug,
      name: brand.name,
      role: place_brand.role
    })
    |> repo.all()
    |> Enum.group_by(& &1.place_id, &Map.delete(&1, :place_id))
  end

  defp list_operators(_repo, []), do: %{}

  defp list_operators(repo, place_ids) do
    PlaceOperator
    |> join(:inner, [place_operator], organization in Organization,
      on: organization.id == place_operator.organization_id
    )
    |> where([place_operator], place_operator.place_id in ^place_ids)
    |> where(
      [place_operator],
      fragment("? @> statement_timestamp()", place_operator.valid_during)
    )
    |> where([_place_operator, organization], organization.status == "active")
    |> order_by(
      [place_operator, organization],
      asc: place_operator.place_id,
      asc: organization.trade_name,
      asc: organization.id
    )
    |> select([place_operator, organization], %{
      place_id: place_operator.place_id,
      organization_id: organization.id,
      trade_name: organization.trade_name,
      role: place_operator.role
    })
    |> repo.all()
    |> Enum.group_by(& &1.place_id, &Map.delete(&1, :place_id))
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
         {:ok, place_id} <- Ecto.UUID.cast(decoded) do
      {:ok, place_id}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_places, false), do: nil

  defp next_cursor(places, true) do
    places
    |> List.last()
    |> Map.fetch!(:place_id)
    |> Base.url_encode64(padding: false)
  end
end
