defmodule Clubeira.Partnerships.AgreementReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Partnerships.AgreementBrand
  alias Clubeira.Partnerships.AgreementEdition
  alias Clubeira.Partnerships.AgreementOfferVersion
  alias Clubeira.Partnerships.AgreementOrganization
  alias Clubeira.Partnerships.AgreementPolo
  alias Clubeira.Partnerships.AgreementPoloPlace
  alias Clubeira.Partnerships.AgreementTerm
  alias Clubeira.Partnerships.PartnerAgreement
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @default_limit 20
  @maximum_limit 100
  @statuses ~w(draft active suspended terminated expired)

  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, cursor} <- parse_cursor(Map.get(params, "after")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, cursor, limit)
      )
    end
  end

  def list(_scope, _params), do: {:error, :partner_admin_required}

  @spec get(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{actor_user_id: nil}, _agreement_id), do: {:error, :partner_admin_required}

  def get(%Scope{} = scope, agreement_id) do
    case Ecto.UUID.cast(agreement_id) do
      {:ok, agreement_id} ->
        Repo.transact_in_polo(scope, &get_authorized(&1, scope, agreement_id))

      :error ->
        {:error, :partner_agreement_not_found}
    end
  end

  def get(_scope, _agreement_id), do: {:error, :partner_admin_required}

  defp list_authorized(repo, scope, status, cursor, limit) do
    case Authorization.authorize(repo, scope, :manage_partners, transaction_time(repo)) do
      :ok -> {:ok, agreement_page(repo, scope.polo_id, status, cursor, limit)}
      {:error, _reason} = error -> error
    end
  end

  defp get_authorized(repo, scope, agreement_id) do
    case Authorization.authorize(repo, scope, :manage_partners, transaction_time(repo)) do
      :ok -> fetch_agreement(repo, scope.polo_id, agreement_id)
      {:error, _reason} = error -> error
    end
  end

  defp fetch_agreement(repo, polo_id, agreement_id) do
    case fetch_agreements(repo, polo_id, [agreement_id]) do
      [agreement] -> {:ok, agreement}
      [] -> {:error, :partner_agreement_not_found}
    end
  end

  defp agreement_page(repo, polo_id, status, cursor, limit) do
    rows =
      AgreementPolo
      |> join(:inner, [link], agreement in PartnerAgreement,
        on: agreement.id == link.partner_agreement_id
      )
      |> where([link], link.polo_id == ^polo_id)
      |> with_status(status)
      |> after_cursor(cursor)
      |> order_by([_link, agreement], desc: agreement.inserted_at, desc: agreement.id)
      |> select([_link, agreement], %{id: agreement.id, recorded_at: agreement.inserted_at})
      |> limit(^(limit + 1))
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, limit)
    has_more = overflow != []

    %{
      agreements: fetch_agreements(repo, polo_id, Enum.map(page_rows, & &1.id)),
      page: %{
        limit: limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp fetch_agreements(_repo, _polo_id, []), do: []

  defp fetch_agreements(repo, polo_id, ids) do
    agreements =
      AgreementPolo
      |> join(:inner, [link], agreement in PartnerAgreement,
        on: agreement.id == link.partner_agreement_id
      )
      |> where([link], link.polo_id == ^polo_id and link.partner_agreement_id in ^ids)
      |> order_by([_link, agreement], desc: agreement.inserted_at, desc: agreement.id)
      |> select([_link, agreement], agreement)
      |> repo.all()

    aggregates = aggregate_graph(repo, polo_id, ids)

    Enum.map(agreements, fn agreement ->
      graph = Map.fetch!(aggregates, agreement.id)
      serialize(agreement, graph)
    end)
  end

  defp aggregate_graph(repo, polo_id, ids) do
    terms = latest_terms(repo, ids)
    organizations = ids_by_agreement(repo, AgreementOrganization, :organization_id, ids)
    brands = ids_by_agreement(repo, AgreementBrand, :brand_id, ids)
    polos = ids_by_agreement(repo, AgreementPolo, :polo_id, ids)

    polo_places =
      tenant_ids_by_agreement(repo, AgreementPoloPlace, :polo_place_id, polo_id, ids)

    editions = tenant_ids_by_agreement(repo, AgreementEdition, :edition_id, polo_id, ids)

    offers =
      tenant_ids_by_agreement(
        repo,
        AgreementOfferVersion,
        :benefit_offer_version_id,
        polo_id,
        ids
      )

    Map.new(ids, fn id ->
      {id,
       %{
         term: Map.get(terms, id),
         organization_ids: Map.get(organizations, id, []),
         brand_ids: Map.get(brands, id, []),
         polo_ids: Map.get(polos, id, []),
         polo_place_ids: Map.get(polo_places, id, []),
         edition_ids: Map.get(editions, id, []),
         benefit_offer_version_ids: Map.get(offers, id, [])
       }}
    end)
  end

  defp latest_terms(repo, ids) do
    AgreementTerm
    |> where([term], term.partner_agreement_id in ^ids)
    |> distinct([term], term.partner_agreement_id)
    |> order_by([term], asc: term.partner_agreement_id, desc: term.version)
    |> repo.all()
    |> Map.new(&{&1.partner_agreement_id, &1})
  end

  defp ids_by_agreement(repo, schema, field, ids) do
    schema
    |> where([link], link.partner_agreement_id in ^ids)
    |> select([link], {link.partner_agreement_id, field(link, ^field)})
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, values} -> {id, Enum.sort(values)} end)
  end

  defp tenant_ids_by_agreement(repo, schema, field, polo_id, ids) do
    schema
    |> where([link], link.polo_id == ^polo_id and link.partner_agreement_id in ^ids)
    |> select([link], {link.partner_agreement_id, field(link, ^field)})
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, values} -> {id, Enum.sort(values)} end)
  end

  defp serialize(agreement, graph) do
    term = graph.term

    %{
      "id" => agreement.id,
      "agreement_number" => agreement.agreement_number,
      "name" => agreement.name,
      "status" => agreement.status,
      "valid_from" => DateTime.to_iso8601(agreement.valid_during.lower),
      "valid_until" => range_bound(agreement.valid_during.upper),
      "signed_at" => datetime(agreement.signed_at),
      "terms" => serialize_term(term),
      "organization_ids" => graph.organization_ids,
      "brand_ids" => graph.brand_ids,
      "polo_ids" => graph.polo_ids,
      "polo_place_ids" => graph.polo_place_ids,
      "edition_ids" => graph.edition_ids,
      "benefit_offer_version_ids" => graph.benefit_offer_version_ids
    }
  end

  defp serialize_term(nil), do: nil

  defp serialize_term(term) do
    %{
      "id" => term.id,
      "version" => term.version,
      "settlement_model" => term.settlement_model,
      "redemption_sla_seconds" => term.redemption_sla_seconds,
      "published_at" => datetime(term.published_at)
    }
  end

  defp with_status(query, nil), do: query

  defp with_status(query, status),
    do: where(query, [_link, agreement], agreement.status == ^status)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [_link, agreement],
      agreement.inserted_at < ^recorded_at or
        (agreement.inserted_at == ^recorded_at and agreement.id < ^id)
    )
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@maximum_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(_value), do: {:error, :invalid_pagination}

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(value) when value in @statuses, do: {:ok, value}
  defp parse_status(_value), do: {:error, :invalid_partner_agreement_status}

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(value) when is_binary(value) and byte_size(value) <= 128 do
    with {:ok, <<timestamp::signed-64, uuid::binary-size(16)>>} <-
           Base.url_decode64(value, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(timestamp, :microsecond),
         {:ok, id} <- Ecto.UUID.load(uuid) do
      {:ok, %{recorded_at: recorded_at, id: id}}
    else
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp parse_cursor(_value), do: {:error, :invalid_pagination}

  defp next_cursor(_rows, false), do: nil

  defp next_cursor(rows, true) do
    %{recorded_at: recorded_at, id: id} = List.last(rows)

    <<DateTime.to_unix(recorded_at, :microsecond)::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)
  defp range_bound(:unbound), do: nil
  defp range_bound(value), do: datetime(value)

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
