defmodule Clubeira.Polos.PublicDirectoryReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.City
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo

  @default_page_limit 20
  @maximum_page_limit 100
  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @spec list(map()) ::
          {:ok, %{polos: [map()], page: map()}} | {:error, :invalid_pagination | term()}
  def list(params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params) do
      Repo.transact(fn repo -> {:ok, page(repo, pagination)} end)
    end
  end

  def list(_params), do: {:error, :invalid_pagination}

  defp page(repo, pagination) do
    query_limit = pagination.limit + 1

    rows =
      Polo
      |> join(:inner, [polo], route in PoloRoute, on: route.polo_id == polo.id)
      |> join(:inner, [polo], city in City, on: city.id == polo.city_id)
      |> where([polo], polo.status == "active")
      |> after_slug(pagination.after)
      |> order_by([_polo, route], asc: route.slug)
      |> select([polo, route, city], %{
        id: polo.id,
        slug: route.slug,
        name: polo.name,
        timezone: polo.timezone,
        city: %{
          id: city.id,
          name: city.name,
          subdivision_code: city.subdivision_code,
          country_code: city.country_code,
          timezone: city.timezone
        }
      })
      |> limit(^query_limit)
      |> repo.all()

    {polos, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      polos: polos,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(polos, has_more)
      }
    }
  end

  defp after_slug(query, nil), do: query
  defp after_slug(query, slug), do: where(query, [_polo, route], route.slug > ^slug)

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_slug} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_slug}}
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
    with {:ok, slug} <- Base.url_decode64(cursor, padding: false),
         true <- valid_slug?(slug) do
      {:ok, slug}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp valid_slug?(slug) do
    byte_size(slug) in 2..80 and Regex.match?(@slug_pattern, slug)
  end

  defp next_cursor(_polos, false), do: nil

  defp next_cursor(polos, true) do
    polos
    |> List.last()
    |> Map.fetch!(:slug)
    |> Base.url_encode64(padding: false)
  end
end
