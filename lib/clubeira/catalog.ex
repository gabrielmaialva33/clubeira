defmodule Clubeira.Catalog do
  @moduledoc """
  Published catalog reads and administrative publication commands for a polo.

  A public route may resolve the tenant before authentication, but all tenant
  data is still read inside `Clubeira.Repo.transact_in_polo/3` and filtered to
  currently active, published records.
  """

  import Ecto.Query

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferPublisher
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Polos
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessProduct
  alias Clubeira.Subscriptions.AccessProductVersion
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Subscriptions.Provisioner
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100

  @type public_catalog :: %{
          polo: %{id: Ecto.UUID.t(), slug: String.t(), name: String.t(), timezone: String.t()},
          offers: [map()],
          page: %{limit: pos_integer(), has_more: boolean(), next_cursor: String.t() | nil}
        }

  @type fetch_error :: :invalid_pagination | :polo_not_found

  @doc """
  Publishes a new benefit and its immutable first version at one active place.
  """
  @spec publish_benefit_offer(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, BenefitOfferPublisher.result()} | {:error, term()}
  defdelegate publish_benefit_offer(scope, place_id, attributes),
    to: BenefitOfferPublisher,
    as: :publish

  @spec fetch_public(String.t(), map()) :: {:ok, public_catalog()} | {:error, fetch_error()}
  def fetch_public(slug, params \\ %{})

  def fetch_public(slug, params) when is_binary(slug) and is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, route} <- Polos.resolve_route(slug) do
      fetch_public_in_route(route, pagination)
    end
  end

  def fetch_public(_slug, _params), do: {:error, :polo_not_found}

  @spec fetch_checkout_options(String.t(), map()) ::
          {:ok, %{polo: map(), options: [map()], page: map()}} | {:error, fetch_error()}
  def fetch_checkout_options(slug, params \\ %{})

  def fetch_checkout_options(slug, params) when is_binary(slug) and is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, route} <- Polos.resolve_route(slug) do
      fetch_checkout_options_in_route(route, pagination)
    end
  end

  def fetch_checkout_options(_slug, _params), do: {:error, :polo_not_found}

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

  defp fetch_checkout_options_in_route(%PoloRoute{} = route, pagination) do
    scope = Scope.new!(route.polo_id)

    Repo.transact_in_polo(scope, fn repo ->
      case repo.get(Polo, route.polo_id) do
        %Polo{status: "active"} = polo ->
          %{options: options, page: page} =
            list_checkout_options(repo, polo.id, pagination)

          {:ok,
           %{
             polo: %{
               id: polo.id,
               slug: route.slug,
               name: polo.name,
               timezone: polo.timezone
             },
             options: options,
             page: page
           }}

        %Polo{} ->
          {:error, :polo_not_found}

        nil ->
          {:error, :polo_not_found}
      end
    end)
  end

  defp list_checkout_options(repo, polo_id, pagination) do
    query_limit = pagination.limit + 1
    scope = Scope.new!(polo_id)
    now = transaction_time(repo)

    rows =
      OfferingPrice
      |> join_checkout_option_relations()
      |> filter_checkout_price(polo_id)
      |> filter_checkout_offering_version()
      |> filter_direct_offering()
      |> filter_active_product()
      |> filter_assigned_package()
      |> after_checkout_option(pagination.after_id)
      |> order_by([price], asc: price.id)
      |> select_checkout_option()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    options =
      Enum.flat_map(page_rows, fn {option, version} ->
        case Provisioner.validate_for_checkout(repo, scope, version, now) do
          :ok -> [option]
          {:error, _reason} -> []
        end
      end)

    %{
      options: options,
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_checkout_option_cursor(page_rows, has_more)
      }
    }
  end

  defp join_checkout_option_relations(query) do
    query
    |> join(:inner, [price], version in ProductOfferingVersion,
      on: version.id == price.product_offering_version_id and version.polo_id == price.polo_id
    )
    |> join(:inner, [_price, version], offering in ProductOffering,
      on: offering.id == version.product_offering_id and offering.polo_id == version.polo_id
    )
    |> join(:inner, [_price, _version, offering], product_version in AccessProductVersion,
      on:
        product_version.id == offering.access_product_version_id and
          product_version.polo_id == offering.polo_id
    )
    |> join(:inner, [_price, _version, _offering, product_version], product in AccessProduct,
      on:
        product.id == product_version.access_product_id and
          product.polo_id == product_version.polo_id
    )
  end

  defp filter_checkout_price(query, polo_id) do
    query
    |> where([price], price.polo_id == ^polo_id)
    |> where([price], price.billing_model == "subscription")
    |> where([price], fragment("? @> statement_timestamp()", price.valid_during))
  end

  defp filter_checkout_offering_version(query) do
    query
    |> where([_price, version], version.status == "published")
    |> where([_price, version], version.activation_policy == "payment_confirmation")
    |> where([_price, version], version.cycle_policy in ["anniversary", "calendar"])
    |> where(
      [_price, version],
      fragment("? @> statement_timestamp()", version.effective_during)
    )
  end

  defp filter_direct_offering(query) do
    query
    |> where([_price, _version, offering], offering.status == "active")
    |> where([_price, _version, offering], offering.sales_channel == "direct")
  end

  defp filter_active_product(query) do
    query
    |> where(
      [_price, _version, _offering, product_version],
      product_version.status == "published"
    )
    |> where(
      [_price, _version, _offering, _product_version, product],
      product.status == "active"
    )
  end

  defp filter_assigned_package(query) do
    where(
      query,
      [price, _version, _offering, _product_version, _product],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM product_offering_package_assignments AS assignment
          JOIN benefit_package_versions AS package_version
            ON package_version.id = assignment.benefit_package_version_id
           AND package_version.polo_id = assignment.polo_id
          WHERE assignment.polo_id = ?
            AND assignment.product_offering_version_id = ?
            AND assignment.valid_during @> statement_timestamp()
            AND package_version.status = 'published'
            AND EXISTS (
              SELECT 1
              FROM benefit_package_items AS item
              WHERE item.polo_id = assignment.polo_id
                AND item.benefit_package_version_id = package_version.id
            )
        )
        """,
        price.polo_id,
        price.product_offering_version_id
      )
    )
  end

  defp select_checkout_option(query) do
    select(
      query,
      [price, version],
      {%{
         product_offering_version_id: version.id,
         offering_price_id: price.id,
         name: version.name,
         description: version.description,
         cycle_policy: version.cycle_policy,
         cycle_interval_unit: version.cycle_interval_unit,
         cycle_interval_count: version.cycle_interval_count,
         renewal_policy: version.renewal_policy,
         price_key: price.price_key,
         currency: price.currency,
         amount: price.amount,
         billing_model: price.billing_model,
         billing_interval_unit: price.billing_interval_unit,
         billing_interval_count: price.billing_interval_count,
         installments: price.installments
       }, version}
    )
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

  defp after_checkout_option(query, nil), do: query

  defp after_checkout_option(query, price_id) do
    where(query, [price], price.id > ^price_id)
  end

  defp next_cursor(_rows, false), do: nil

  defp next_cursor(rows, true) do
    rows
    |> List.last()
    |> Map.fetch!(:offer_version_id)
    |> Base.url_encode64(padding: false)
  end

  defp next_checkout_option_cursor(_options, false), do: nil

  defp next_checkout_option_cursor(rows, true) do
    rows
    |> List.last()
    |> elem(0)
    |> Map.fetch!(:offering_price_id)
    |> Base.url_encode64(padding: false)
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
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
