defmodule Clubeira.Directory do
  @moduledoc """
  Partner onboarding and public discovery of active commercial places.

  Places, brands and organizations are global identities. A public listing is
  still entered through `polo_places` inside the routed polo's RLS boundary.
  """

  import Ecto.Query

  alias Clubeira.Directory.Address
  alias Clubeira.Directory.BackofficePlaceReader
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.PartnerAccessGrantor
  alias Clubeira.Directory.PartnerAccessRevoker
  alias Clubeira.Directory.PartnerOnboarder
  alias Clubeira.Directory.PartnerPlaceReader
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceBrand
  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Directory.PlaceParticipationLifecycle
  alias Clubeira.Directory.PlaceParticipationLifecycleRequest
  alias Clubeira.Directory.PlaceProfilePublisher
  alias Clubeira.Directory.PlaceProfileView
  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Directory.PoloPlaceProfileCategory
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

  @doc """
  Onboards a partner and its first place into an authorized polo.
  """
  @spec onboard_partner(Scope.t(), map()) ::
          {:ok, PartnerOnboarder.result()} | {:error, atom() | Ecto.Changeset.t()}
  def onboard_partner(%Scope{} = scope, attributes) when is_map(attributes) do
    PartnerOnboarder.onboard(scope, attributes)
  end

  def onboard_partner(_scope, _attributes), do: {:error, :partner_admin_required}

  @doc """
  Grants a verified account partner access to one operated place in the polo.
  """
  @spec grant_partner_access(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, PartnerAccessGrantor.result()} | {:error, atom() | Ecto.Changeset.t()}
  def grant_partner_access(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    PartnerAccessGrantor.grant(scope, place_id, attributes)
  end

  def grant_partner_access(_scope, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  @doc """
  Revokes one dedicated partner access inside an authorized polo.
  """
  @spec revoke_partner_access(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, PartnerAccessRevoker.result()} | {:error, atom() | Ecto.Changeset.t()}
  def revoke_partner_access(%Scope{} = scope, access_id, attributes) when is_map(attributes) do
    PartnerAccessRevoker.revoke(scope, access_id, attributes)
  end

  def revoke_partner_access(_scope, _access_id, _attributes),
    do: {:error, :partner_admin_required}

  @doc """
  Lists active places managed by the authenticated partner inside one polo.
  """
  @spec list_partner_places(Scope.t(), map()) ::
          {:ok, %{places: [map()], page: map()}} | {:error, term()}
  defdelegate list_partner_places(scope, params), to: PartnerPlaceReader, as: :list

  @doc """
  Replaces the public profile of an active place participation.
  """
  @spec publish_place_profile(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, PlaceProfilePublisher.result()} | {:error, atom() | Ecto.Changeset.t()}
  def publish_place_profile(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    PlaceProfilePublisher.publish(scope, place_id, attributes)
  end

  def publish_place_profile(_scope, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  @doc """
  Suspends, reactivates or retires one exact participation of a place in a polo.

  The expected participation identity and revision protect the command from
  stale forms and replacement-participation ABA races.
  """
  @spec transition_place_participation(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, PlaceParticipationLifecycle.result()}
          | {:error, atom() | Ecto.Changeset.t()}
  def transition_place_participation(%Scope{} = scope, place_id, attributes)
      when is_map(attributes) do
    PlaceParticipationLifecycle.transition(scope, place_id, attributes)
  end

  def transition_place_participation(_scope, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  @doc false
  @spec change_place_participation_lifecycle(term()) :: Ecto.Changeset.t()
  def change_place_participation_lifecycle(attributes \\ %{}) do
    PlaceParticipationLifecycleRequest.change(attributes)
  end

  @doc """
  Lists polo participation records even when their public profile is missing.
  """
  @spec list_backoffice_places(Scope.t(), map()) ::
          {:ok, %{places: [map()], page: map()}} | {:error, term()}
  defdelegate list_backoffice_places(scope, params), to: BackofficePlaceReader, as: :list

  @doc """
  Gets one exact place participation inside an authorized polo.
  """
  @spec get_backoffice_place(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :partner_admin_required | :place_not_found | term()}
  defdelegate get_backoffice_place(scope, polo_place_id), to: BackofficePlaceReader, as: :get

  @doc """
  Lists the active global category catalog for an authorized place editor.
  """
  @spec list_backoffice_place_categories(Scope.t()) ::
          {:ok, [map()]} | {:error, :partner_admin_required | term()}
  defdelegate list_backoffice_place_categories(scope),
    to: BackofficePlaceReader,
    as: :list_categories

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
    polo_place_ids = Enum.map(page_rows, & &1.polo_place_id)
    brands_by_place = list_brands(repo, place_ids)
    operators_by_place = list_operators(repo, place_ids)
    profiles_by_polo_place = list_profiles(repo, polo_id, polo_place_ids)

    places =
      Enum.map(page_rows, fn place ->
        place
        |> Map.put(:brands, Map.get(brands_by_place, place.place_id, []))
        |> Map.put(:operators, Map.get(operators_by_place, place.place_id, []))
        |> Map.put(:profile, Map.get(profiles_by_polo_place, place.polo_place_id))
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

  defp list_profiles(_repo, _polo_id, []), do: %{}

  defp list_profiles(repo, polo_id, polo_place_ids) do
    profiles =
      PoloPlaceProfile
      |> where(
        [profile],
        profile.polo_id == ^polo_id and profile.polo_place_id in ^polo_place_ids
      )
      |> repo.all()

    profile_ids = Enum.map(profiles, & &1.id)
    categories_by_profile = list_profile_categories(repo, profile_ids)
    periods_by_profile = list_profile_periods(repo, profile_ids)

    Map.new(profiles, fn profile ->
      profile_data =
        PlaceProfileView.build(
          profile,
          Map.get(categories_by_profile, profile.id, []),
          Map.get(periods_by_profile, profile.id, [])
        )

      {profile.polo_place_id, profile_data}
    end)
  end

  defp list_profile_categories(_repo, []), do: %{}

  defp list_profile_categories(repo, profile_ids) do
    PoloPlaceProfileCategory
    |> join(:inner, [profile_category], category in PlaceCategory,
      on: category.id == profile_category.place_category_id
    )
    |> where([profile_category], profile_category.polo_place_profile_id in ^profile_ids)
    |> where([_profile_category, category], category.status == "active")
    |> select([profile_category, category], %{
      profile_id: profile_category.polo_place_profile_id,
      key: category.key,
      name: category.name,
      display_order: category.display_order
    })
    |> repo.all()
    |> Enum.group_by(& &1.profile_id, &Map.delete(&1, :profile_id))
  end

  defp list_profile_periods(_repo, []), do: %{}

  defp list_profile_periods(repo, profile_ids) do
    PoloPlaceOpeningPeriod
    |> where([period], period.polo_place_profile_id in ^profile_ids)
    |> repo.all()
    |> Enum.group_by(& &1.polo_place_profile_id)
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
