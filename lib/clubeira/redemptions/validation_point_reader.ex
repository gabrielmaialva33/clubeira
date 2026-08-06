defmodule Clubeira.Redemptions.ValidationPointReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @statuses ~w(active suspended retired)

  @spec list(Scope.t(), map()) ::
          {:ok, %{validation_points: [map()], page: map()}}
          | {:error,
             :invalid_pagination
             | :invalid_place_id
             | :invalid_validation_point_status
             | :partner_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, place_id} <- parse_place_id(Map.get(params, "place_id")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, place_id, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_admin_required}

  defp list_authorized(repo, scope, status, place_id, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_partners, transaction_time(repo)) do
      {:ok, validation_point_page(repo, scope, status, place_id, pagination)}
    end
  end

  defp validation_point_page(repo, scope, status, place_id, pagination) do
    query_limit = pagination.limit + 1

    rows =
      ValidationPoint
      |> join(:inner, [point], polo_place in PoloPlace,
        on: polo_place.id == point.polo_place_id and polo_place.polo_id == point.polo_id
      )
      |> join(:inner, [_point, polo_place], place in Place, on: place.id == polo_place.place_id)
      |> join_latest_credential(scope.polo_id)
      |> where([point], point.polo_id == ^scope.polo_id)
      |> with_status(status)
      |> with_place(place_id)
      |> after_validation_point(pagination.after)
      |> order_by([point], desc: point.inserted_at, desc: point.id)
      |> select_validation_point()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      validation_points: Enum.map(page_rows, &validation_point_data/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp join_latest_credential(query, polo_id) do
    latest_credentials =
      from credential in ValidationCredential,
        where: credential.polo_id == ^polo_id,
        distinct: [credential.validation_point_id],
        order_by: [asc: credential.validation_point_id, desc: credential.version],
        select: %{
          id: credential.id,
          validation_point_id: credential.validation_point_id,
          version: credential.version,
          kind: credential.kind,
          status: credential.status,
          valid_during: credential.valid_during
        }

    join(query, :left, [point], credential in subquery(latest_credentials),
      on: credential.validation_point_id == point.id
    )
  end

  defp select_validation_point(query) do
    select(query, [point, polo_place, place, credential], %{
      id: point.id,
      polo_place_id: point.polo_place_id,
      name: point.name,
      kind: point.kind,
      status: point.status,
      revision: point.revision,
      recorded_at: point.inserted_at,
      place_id: polo_place.place_id,
      place_name: place.name,
      place_slug: place.slug,
      place_status: place.status,
      credential_id: credential.id,
      credential_version: credential.version,
      credential_kind: credential.kind,
      credential_status: credential.status,
      credential_valid_during: credential.valid_during
    })
  end

  defp validation_point_data(row) do
    %{
      id: row.id,
      polo_place_id: row.polo_place_id,
      name: row.name,
      kind: row.kind,
      status: row.status,
      revision: row.revision,
      recorded_at: row.recorded_at,
      place: %{
        id: row.place_id,
        name: row.place_name,
        slug: row.place_slug,
        status: row.place_status
      },
      credential: credential_data(row)
    }
  end

  defp credential_data(%{credential_id: nil}), do: nil

  defp credential_data(row) do
    %Postgrex.Range{lower: valid_from, upper: expires_at} = row.credential_valid_during

    %{
      id: row.credential_id,
      version: row.credential_version,
      kind: row.credential_kind,
      status: row.credential_status,
      valid_from: valid_from,
      expires_at: expires_at
    }
  end

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: where(query, [point], point.status == ^status)

  defp with_place(query, nil), do: query

  defp with_place(query, place_id),
    do: where(query, [_point, _polo_place, place], place.id == ^place_id)

  defp after_validation_point(query, nil), do: query

  defp after_validation_point(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [point],
      point.inserted_at < ^recorded_at or
        (point.inserted_at == ^recorded_at and point.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_point} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_point}}
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
    with {:ok, <<unix_microsecond::signed-64, point_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, point_id} <- Ecto.UUID.load(point_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: point_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_points, false), do: nil

  defp next_cursor(points, true) do
    %{recorded_at: recorded_at, id: id} = List.last(points)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_validation_point_status}

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
