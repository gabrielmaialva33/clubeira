defmodule Clubeira.Partnerships.AgreementOptionsReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.Edition
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.BrandOwnership
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec list(Scope.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{actor_user_id: nil}), do: {:error, :partner_admin_required}

  def list(%Scope{} = scope) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      case Authorization.authorize(repo, scope, :manage_partners, now) do
        :ok -> {:ok, options(repo, scope.polo_id, now)}
        {:error, _reason} = error -> error
      end
    end)
  end

  def list(_scope), do: {:error, :partner_admin_required}

  defp options(repo, polo_id, now) do
    organizations = organizations(repo, polo_id, now)
    organization_ids = Enum.map(organizations, & &1.id)

    %{
      organizations: organizations,
      brands: brands(repo, organization_ids, now),
      places: places(repo, polo_id, now),
      editions: editions(repo, polo_id),
      benefit_offer_versions: benefit_offer_versions(repo, polo_id, now)
    }
  end

  defp organizations(repo, polo_id, now) do
    PoloPlace
    |> join(:inner, [polo_place], place in Place, on: place.id == polo_place.place_id)
    |> join(:inner, [_polo_place, place], operator in PlaceOperator,
      on: operator.place_id == place.id
    )
    |> join(:inner, [_polo_place, _place, operator], organization in Organization,
      on: organization.id == operator.organization_id
    )
    |> where(
      [polo_place, place, operator, organization],
      polo_place.polo_id == ^polo_id and polo_place.status == "active" and
        place.status == "active" and operator.role == "operator" and
        organization.status == "active"
    )
    |> where(
      [polo_place],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        polo_place.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> where(
      [_polo_place, _place, operator],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        operator.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> group_by([_polo_place, _place, _operator, organization], [
      organization.id,
      organization.legal_name,
      organization.trade_name
    ])
    |> order_by([_polo_place, _place, _operator, organization],
      asc: fragment("COALESCE(?, ?)", organization.trade_name, organization.legal_name),
      asc: organization.id
    )
    |> select([_polo_place, _place, _operator, organization], %{
      id: organization.id,
      name: fragment("COALESCE(?, ?)", organization.trade_name, organization.legal_name),
      legal_name: organization.legal_name
    })
    |> repo.all()
  end

  defp brands(_repo, [], _now), do: []

  defp brands(repo, organization_ids, now) do
    BrandOwnership
    |> join(:inner, [ownership], brand in Brand, on: brand.id == ownership.brand_id)
    |> where(
      [ownership, brand],
      ownership.organization_id in ^organization_ids and brand.status == "active"
    )
    |> where(
      [ownership],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        ownership.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> group_by([_ownership, brand], [brand.id, brand.name])
    |> order_by([_ownership, brand], asc: brand.name, asc: brand.id)
    |> select([ownership, brand], %{
      id: brand.id,
      name: brand.name,
      organization_ids:
        type(
          fragment(
            "array_agg(DISTINCT ? ORDER BY ?)",
            ownership.organization_id,
            ownership.organization_id
          ),
          {:array, Ecto.UUID}
        )
    })
    |> repo.all()
  end

  defp places(repo, polo_id, now) do
    PoloPlace
    |> join(:inner, [polo_place], place in Place, on: place.id == polo_place.place_id)
    |> join(:inner, [_polo_place, place], operator in PlaceOperator,
      on: operator.place_id == place.id
    )
    |> join(:inner, [_polo_place, _place, operator], organization in Organization,
      on: organization.id == operator.organization_id
    )
    |> where(
      [polo_place, place, operator, organization],
      polo_place.polo_id == ^polo_id and polo_place.status == "active" and
        place.status == "active" and operator.role == "operator" and
        organization.status == "active"
    )
    |> where(
      [polo_place],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        polo_place.participation_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> where(
      [_polo_place, _place, operator],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        operator.valid_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> group_by([polo_place, place], [polo_place.id, place.id, place.name, place.slug])
    |> order_by([_polo_place, place], asc: place.name, asc: place.id)
    |> select([polo_place, place, operator], %{
      id: polo_place.id,
      place_id: place.id,
      name: place.name,
      slug: place.slug,
      organization_ids:
        type(
          fragment(
            "array_agg(DISTINCT ? ORDER BY ?)",
            operator.organization_id,
            operator.organization_id
          ),
          {:array, Ecto.UUID}
        )
    })
    |> repo.all()
  end

  defp editions(repo, polo_id) do
    Edition
    |> where(
      [edition],
      edition.polo_id == ^polo_id and edition.status in ["on_sale", "active"]
    )
    |> order_by([edition], asc: edition.name, asc: edition.id)
    |> select([edition], %{
      id: edition.id,
      code: edition.code,
      name: edition.name,
      status: edition.status
    })
    |> repo.all()
  end

  defp benefit_offer_versions(repo, polo_id, now) do
    BenefitOfferVersion
    |> join(:inner, [version], offer in BenefitOffer,
      on: offer.id == version.benefit_offer_id and offer.polo_id == version.polo_id
    )
    |> where(
      [version, offer],
      version.polo_id == ^polo_id and version.status == "published" and
        offer.status == "active"
    )
    |> where(
      [version],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        version.effective_during,
        type(^now, :utc_datetime_usec)
      )
    )
    |> order_by([_version, offer], asc: offer.name, asc: offer.id)
    |> select([version, offer], %{
      id: version.id,
      title: version.title,
      benefit_offer_id: offer.id,
      benefit_offer_name: offer.name,
      benefit_kind: offer.benefit_kind
    })
    |> repo.all()
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
