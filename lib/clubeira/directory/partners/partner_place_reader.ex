defmodule Clubeira.Directory.PartnerPlaceReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.BackofficePlaceProfileView
  alias Clubeira.Directory.PartnerPlaceAccess
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Directory.PoloPlaceProfileCategory
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @spec list(Scope.t(), map()) ::
          {:ok, %{places: [map()], page: map()}}
          | {:error, :invalid_pagination | :partner_access_required | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_access_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params) do
      Repo.transact_in_polo(scope, &list_authorized(&1, scope, pagination))
    end
  end

  def list(_scope, _params), do: {:error, :partner_access_required}

  @spec get(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :partner_access_required | :place_not_found | term()}
  def get(%Scope{actor_user_id: nil}, _polo_place_id),
    do: {:error, :partner_access_required}

  def get(%Scope{} = scope, polo_place_id) do
    with {:ok, polo_place_id} <- cast_place_id(polo_place_id) do
      Repo.transact_in_polo(scope, &get_authorized(&1, scope, polo_place_id))
    end
  end

  def get(_scope, _polo_place_id), do: {:error, :partner_access_required}

  @spec list_categories(Scope.t()) ::
          {:ok, [map()]} | {:error, :partner_access_required | term()}
  def list_categories(%Scope{actor_user_id: nil}), do: {:error, :partner_access_required}

  def list_categories(%Scope{} = scope) do
    Repo.transact_in_polo(scope, &list_categories_authorized(&1, scope))
  end

  def list_categories(_scope), do: {:error, :partner_access_required}

  defp list_authorized(repo, scope, pagination) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now) do
      {:ok, place_page(repo, scope, pagination, now)}
    end
  end

  defp get_authorized(repo, scope, polo_place_id) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now) do
      place =
        scope
        |> partner_places_query(now)
        |> where([polo_place: participation], participation.id == ^polo_place_id)
        |> select_place()
        |> repo.one()

      if place do
        {:ok, place |> place_data() |> Map.put(:profile, full_profile(repo, place))}
      else
        {:error, :place_not_found}
      end
    end
  end

  defp list_categories_authorized(repo, scope) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_own_places, now),
         true <- repo.exists?(partner_places_query(scope, now)) do
      categories =
        PlaceCategory
        |> where([category], category.status == "active")
        |> order_by([category], asc: category.display_order, asc: category.key)
        |> select([category], %{
          key: category.key,
          name: category.name,
          display_order: category.display_order
        })
        |> repo.all()

      {:ok, categories}
    else
      false -> {:error, :partner_access_required}
      {:error, _reason} = error -> error
    end
  end

  defp place_page(repo, scope, pagination, now) do
    query_limit = pagination.limit + 1

    rows =
      scope
      |> partner_places_query(now)
      |> after_place(pagination.after)
      |> order_by([polo_place: participation],
        desc: participation.inserted_at,
        desc: participation.id
      )
      |> select_place()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      places: Enum.map(page_rows, &place_data/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp partner_places_query(scope, now) do
    active_place_ids = PartnerPlaceAccess.active_place_ids_query(scope, now)

    PoloPlace
    |> from(as: :polo_place)
    |> join(:inner, [polo_place: participation], place in Place,
      as: :place,
      on: place.id == participation.place_id
    )
    |> join(:inner, [place: place], access in subquery(active_place_ids),
      as: :partner_access,
      on: access.place_id == place.id
    )
    |> join(:left, [polo_place: participation], profile in PoloPlaceProfile,
      as: :profile,
      on:
        profile.polo_id == participation.polo_id and
          profile.polo_place_id == participation.id
    )
    |> where([polo_place: participation], participation.polo_id == ^scope.polo_id)
    |> where([polo_place: participation], participation.status == "active")
    |> where([place: place], place.status == "active")
    |> where(
      [polo_place: participation],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        participation.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
  end

  defp select_place(query) do
    select(query, [polo_place: participation, place: place, profile: profile], %{
      id: participation.id,
      status: participation.status,
      revision: participation.revision,
      participation_during: participation.participation_during,
      recorded_at: participation.inserted_at,
      place_id: place.id,
      place_name: place.name,
      place_slug: place.slug,
      place_status: place.status,
      place_timezone: place.timezone,
      profile_id: profile.id,
      profile_revision: profile.revision,
      profile_public_email: profile.public_email,
      profile_public_phone: profile.public_phone,
      profile_updated_at: profile.updated_at
    })
  end

  defp place_data(row) do
    %{
      id: row.id,
      status: row.status,
      revision: row.revision,
      participation_during: row.participation_during,
      recorded_at: row.recorded_at,
      place: %{
        id: row.place_id,
        name: row.place_name,
        slug: row.place_slug,
        status: row.place_status,
        timezone: row.place_timezone
      },
      profile: profile_data(row)
    }
  end

  defp profile_data(%{profile_id: nil}), do: nil

  defp profile_data(row) do
    %{
      id: row.profile_id,
      revision: row.profile_revision,
      public_email: row.profile_public_email,
      public_phone: row.profile_public_phone,
      updated_at: row.profile_updated_at
    }
  end

  defp full_profile(_repo, %{profile_id: nil}), do: nil

  defp full_profile(repo, row) do
    profile = repo.get!(PoloPlaceProfile, row.profile_id)

    categories =
      PoloPlaceProfileCategory
      |> join(:inner, [profile_category], category in PlaceCategory,
        on: category.id == profile_category.place_category_id
      )
      |> where(
        [profile_category],
        profile_category.polo_id == ^profile.polo_id and
          profile_category.polo_place_profile_id == ^profile.id
      )
      |> select([_profile_category, category], %{
        key: category.key,
        name: category.name,
        status: category.status,
        display_order: category.display_order
      })
      |> repo.all()

    periods =
      PoloPlaceOpeningPeriod
      |> where(
        [period],
        period.polo_id == ^profile.polo_id and
          period.polo_place_profile_id == ^profile.id
      )
      |> repo.all()

    BackofficePlaceProfileView.build(profile, categories, periods)
  end

  defp after_place(query, nil), do: query

  defp after_place(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [polo_place: participation],
      participation.inserted_at < ^recorded_at or
        (participation.inserted_at == ^recorded_at and participation.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_place} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_place}}
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
    with {:ok, <<unix_microsecond::signed-64, participation_id::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(participation_id) do
      {:ok, %{recorded_at: recorded_at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp cast_place_id(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, place_id} -> {:ok, place_id}
      :error -> {:error, :place_not_found}
    end
  end

  defp next_cursor(_places, false), do: nil

  defp next_cursor(places, true) do
    %{recorded_at: recorded_at, id: id} = List.last(places)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
