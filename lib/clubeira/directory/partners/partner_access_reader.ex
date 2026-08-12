defmodule Clubeira.Directory.PartnerAccessReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Directory.PartnerPlaceAccess
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @partner_role_key "partner_manager"
  @statuses ~w(invited active suspended revoked)
  @email_pattern ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u

  @type page :: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}
  @type partner_access :: %{
          id: Ecto.UUID.t(),
          status: String.t(),
          valid_from: DateTime.t(),
          valid_until: DateTime.t() | nil,
          recorded_at: DateTime.t(),
          user: %{id: Ecto.UUID.t(), email: String.t()},
          places: [%{id: Ecto.UUID.t(), name: String.t()}]
        }

  @spec list(Scope.t(), map()) ::
          {:ok, %{partner_accesses: [partner_access()], page: page()}}
          | {:error,
             :invalid_pagination
             | :invalid_partner_access_email
             | :invalid_partner_access_status
             | :partner_admin_required
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) and not is_struct(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, email} <- parse_email(Map.get(params, "email")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, email, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_admin_required}

  defp list_authorized(repo, scope, status, email, pagination) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
      {:ok, partner_access_page(repo, scope, status, email, pagination, now)}
    end
  end

  defp partner_access_page(repo, scope, status, email, pagination, now) do
    query_limit = pagination.limit + 1

    rows =
      scope
      |> partner_access_query()
      |> with_status(status)
      |> with_email(email)
      |> after_access(pagination.after)
      |> order_by([membership: membership], desc: membership.inserted_at, desc: membership.id)
      |> select_access()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []
    places_by_user = places_by_user(repo, scope, page_rows, now)

    %{
      partner_accesses:
        Enum.map(page_rows, &access_data(&1, Map.get(places_by_user, &1.user_id, []))),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp partner_access_query(scope) do
    PoloMembership
    |> from(as: :membership)
    |> join(:inner, [membership: membership], assignment in PoloMembershipRole,
      as: :role_assignment,
      on:
        assignment.polo_id == membership.polo_id and
          assignment.polo_membership_id == membership.id
    )
    |> join(:inner, [role_assignment: assignment], role in PoloRole,
      as: :role,
      on: role.polo_id == assignment.polo_id and role.id == assignment.polo_role_id
    )
    |> join(:inner, [membership: membership], user in User,
      as: :user,
      on: user.id == membership.user_id
    )
    |> where([membership: membership], membership.polo_id == ^scope.polo_id)
    |> where([role: role], role.key == @partner_role_key)
  end

  defp select_access(query) do
    select(query, [membership: membership, user: user], %{
      id: membership.id,
      status: membership.status,
      valid_during: membership.valid_during,
      recorded_at: membership.inserted_at,
      user_id: user.id,
      user_email: user.email
    })
  end

  defp places_by_user(_repo, _scope, [], _now), do: %{}

  defp places_by_user(repo, scope, rows, now) do
    user_ids = Enum.map(rows, & &1.user_id)
    active_places = PartnerPlaceAccess.active_places_for_users_query(user_ids, now)

    PoloPlace
    |> from(as: :participation)
    |> join(:inner, [participation: participation], place in Place,
      as: :place,
      on: place.id == participation.place_id
    )
    |> join(:inner, [place: place], access in subquery(active_places),
      as: :partner_access,
      on: access.place_id == place.id
    )
    |> where([participation: participation], participation.polo_id == ^scope.polo_id)
    |> where([participation: participation], participation.status == "active")
    |> where([place: place], place.status == "active")
    |> where(
      [participation: participation],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        participation.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> order_by([place: place, partner_access: access],
      asc: access.user_id,
      asc: place.name,
      asc: place.id
    )
    |> select([place: place, partner_access: access], %{
      user_id: access.user_id,
      id: place.id,
      name: place.name
    })
    |> distinct(true)
    |> repo.all()
    |> Enum.group_by(& &1.user_id, &Map.delete(&1, :user_id))
  end

  defp access_data(row, places) do
    %{
      id: row.id,
      status: row.status,
      valid_from: range_bound(row.valid_during.lower),
      valid_until: range_bound(row.valid_during.upper),
      recorded_at: row.recorded_at,
      user: %{id: row.user_id, email: row.user_email},
      places: places
    }
  end

  defp range_bound(:unbound), do: nil
  defp range_bound(value), do: value

  defp with_status(query, nil), do: query

  defp with_status(query, status),
    do: where(query, [membership: membership], membership.status == ^status)

  defp with_email(query, nil), do: query
  defp with_email(query, email), do: where(query, [user: user], user.email == ^email)

  defp after_access(query, nil), do: query

  defp after_access(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [membership: membership],
      membership.inserted_at < ^recorded_at or
        (membership.inserted_at == ^recorded_at and membership.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_access} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_access}}
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
    with {:ok, <<unix_microsecond::signed-64, access_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, access_id} <- Ecto.UUID.load(access_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: access_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_accesses, false), do: nil

  defp next_cursor(accesses, true) do
    %{recorded_at: recorded_at, id: id} = List.last(accesses)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_partner_access_status}

  defp parse_email(nil), do: {:ok, nil}

  defp parse_email(email) when is_binary(email) and byte_size(email) <= 320 do
    if String.valid?(email) do
      normalized = email |> String.trim() |> String.downcase()

      if byte_size(normalized) in 3..320 and Regex.match?(@email_pattern, normalized) do
        {:ok, normalized}
      else
        {:error, :invalid_partner_access_email}
      end
    else
      {:error, :invalid_partner_access_email}
    end
  end

  defp parse_email(_email), do: {:error, :invalid_partner_access_email}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
