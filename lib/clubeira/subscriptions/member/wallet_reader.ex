defmodule Clubeira.Subscriptions.WalletReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Polos
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementScopePlace
  alias Clubeira.Subscriptions.MemberPoloBoundary

  @spec get(AccountScope.t(), String.t()) ::
          {:ok, map()} | {:error, :polo_not_found | term()}
  def get(%AccountScope{} = account_scope, polo_slug) when is_binary(polo_slug) do
    with {:ok, route} <- Polos.resolve_route(polo_slug) do
      MemberPoloBoundary.transact(account_scope, route, fn repo, polo ->
        {:ok, build_wallet(repo, account_scope.user.id, polo)}
      end)
    end
  end

  defp build_wallet(repo, user_id, polo) do
    allocations = list_wallet_allocations(repo, user_id)
    places_by_allocation = list_wallet_places(repo, user_id)

    vouchers =
      Enum.map(allocations, fn allocation ->
        Map.put(allocation, :places, Map.get(places_by_allocation, allocation.allocation_id, []))
      end)

    %{polo: polo, vouchers: vouchers}
  end

  defp list_wallet_allocations(repo, user_id) do
    user_id
    |> wallet_query()
    |> select(
      [
        allocation: allocation,
        subject: subject,
        contract: contract,
        cycle: cycle,
        item: item,
        offer_version: offer_version,
        offer: offer
      ],
      %{
        allocation_id: allocation.id,
        allocation_kind: allocation.allocation_kind,
        issued_units: allocation.issued_units,
        available_units: allocation.available_units,
        contract: %{id: contract.id, status: contract.status},
        cycle: %{
          id: cycle.id,
          sequence: cycle.sequence,
          status: cycle.status,
          starts_at: fragment("lower(?)", cycle.benefits_during),
          ends_at: fragment("upper(?)", cycle.benefits_during)
        },
        subject: %{
          kind: subject.subject_kind,
          contract_beneficiary_id: subject.contract_beneficiary_id
        },
        allowance: %{
          per_cycle: item.allowance_per_cycle,
          consumption_unit: item.consumption_unit,
          subject_policy: item.subject_policy
        },
        offer: %{
          id: offer.id,
          version_id: offer_version.id,
          version: offer_version.version,
          code: offer.code,
          name: offer.name,
          title: offer_version.title,
          description: offer_version.description,
          terms: offer_version.terms,
          redemption_instructions: offer_version.redemption_instructions,
          benefit_kind: offer.benefit_kind,
          percentage_value: offer_version.percentage_value,
          amount_value: offer_version.amount_value,
          currency: offer_version.currency
        }
      }
    )
    |> order_by([allocation: allocation], asc: allocation.id)
    |> repo.all()
  end

  defp list_wallet_places(repo, user_id) do
    user_id
    |> wallet_query()
    |> join(:inner, [offer_version: offer_version], offer_place in BenefitOfferVersionPlace,
      as: :offer_place,
      on:
        offer_place.polo_id == offer_version.polo_id and
          offer_place.benefit_offer_version_id == offer_version.id
    )
    |> join(:inner, [offer_place: offer_place], polo_place in PoloPlace,
      as: :polo_place,
      on:
        polo_place.polo_id == offer_place.polo_id and
          polo_place.id == offer_place.polo_place_id
    )
    |> join(
      :left,
      [allocation: allocation, polo_place: polo_place],
      scope_place in EntitlementScopePlace,
      as: :scope_place,
      on:
        scope_place.polo_id == allocation.polo_id and
          scope_place.entitlement_scope_id == allocation.entitlement_scope_id and
          scope_place.polo_place_id == polo_place.id
    )
    |> join(:inner, [polo_place: polo_place], place in Place,
      as: :place,
      on: place.id == polo_place.place_id
    )
    |> where(
      [allocation: allocation, polo_place: polo_place, scope_place: scope_place],
      (allocation.allocation_kind == "per_place" and
         allocation.polo_place_id == polo_place.id) or
        (allocation.allocation_kind == "shared_scope" and
           not is_nil(scope_place.entitlement_scope_id))
    )
    |> where([polo_place: polo_place], polo_place.status == "active")
    |> where(
      [polo_place: polo_place],
      fragment("? @> statement_timestamp()", polo_place.participation_during)
    )
    |> where([place: place], place.status == "active")
    |> order_by([allocation: allocation, place: place, polo_place: polo_place],
      asc: allocation.id,
      asc: place.name,
      asc: polo_place.id
    )
    |> select([allocation: allocation, polo_place: polo_place, place: place], %{
      allocation_id: allocation.id,
      polo_place_id: polo_place.id,
      place_id: place.id,
      slug: place.slug,
      name: place.name
    })
    |> repo.all()
    |> Enum.group_by(& &1.allocation_id, &Map.delete(&1, :allocation_id))
  end

  defp wallet_query(user_id) do
    EntitlementAllocation
    |> from(as: :allocation)
    |> join_wallet_relations()
    |> filter_wallet_owner(user_id)
    |> filter_current_wallet()
  end

  defp join_wallet_relations(query) do
    query
    |> join(:inner, [allocation: allocation], subject in CycleEntitlementSubject,
      as: :subject,
      on:
        subject.id == allocation.cycle_entitlement_subject_id and
          subject.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, subject: subject], contract in AccessContract,
      as: :contract,
      on:
        contract.id == subject.access_contract_id and
          contract.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, subject: subject], cycle in BenefitCycle,
      as: :cycle,
      on:
        cycle.id == subject.benefit_cycle_id and
          cycle.polo_id == allocation.polo_id and
          cycle.access_contract_id == subject.access_contract_id
    )
    |> join(:inner, [allocation: allocation, cycle: cycle], policy in PoloPolicyVersion,
      as: :policy,
      on:
        policy.id == cycle.polo_policy_version_id and
          policy.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation], item in BenefitPackageItem,
      as: :item,
      on:
        item.id == allocation.benefit_package_item_id and
          item.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, item: item], offer_version in BenefitOfferVersion,
      as: :offer_version,
      on:
        offer_version.id == item.benefit_offer_version_id and
          offer_version.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation: allocation, offer_version: offer_version], offer in BenefitOffer,
      as: :offer,
      on:
        offer.id == offer_version.benefit_offer_id and
          offer.polo_id == allocation.polo_id
    )
  end

  defp filter_wallet_owner(query, user_id) do
    query
    |> where([subject: subject], subject.subject_kind == "contract")
    |> where([contract: contract], contract.purchaser_user_id == ^user_id)
  end

  defp filter_current_wallet(query) do
    query
    |> where(
      [contract: contract, cycle: cycle, policy: policy],
      contract.status == "active" or
        (contract.status == "past_due" and
           policy.delinquency_mode == "grace_period" and
           cycle.delinquency_grace_until >= fragment("statement_timestamp()"))
    )
    |> where(
      [contract: contract],
      is_nil(contract.starts_at) or contract.starts_at <= fragment("statement_timestamp()")
    )
    |> where(
      [contract: contract],
      is_nil(contract.ends_at) or contract.ends_at > fragment("statement_timestamp()")
    )
    |> where([cycle: cycle], cycle.status == "active")
    |> where(
      [cycle: cycle],
      fragment("? @> statement_timestamp()", cycle.benefits_during)
    )
    |> where(
      [allocation: allocation, cycle: cycle, item: item],
      item.benefit_package_version_id == cycle.benefit_package_version_id and
        allocation.entitlement_scope_id == item.entitlement_scope_id and
        allocation.allocation_kind == item.consumption_unit
    )
    |> where([offer: offer], offer.status == "active")
    |> where([offer_version: offer_version], offer_version.status == "published")
    |> where(
      [offer_version: offer_version],
      fragment("? @> statement_timestamp()", offer_version.effective_during)
    )
  end
end
