defmodule Clubeira.Subscriptions.Provisioner do
  @moduledoc """
  Materializes the first contract cycle from one paid subscription order item.

  The caller owns the surrounding transaction and must hold the order lock.
  Configuration is resolved from persisted, versioned records; no package,
  policy, subject, place, or allowance is accepted from the payment boundary.
  """

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.Payment
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Events
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.CycleSchedule
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementScopePlace
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingPackageAssignment
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Subscriptions.ProvisioningPlan
  alias Clubeira.Tenancy.Scope

  @type error_reason ::
          :benefit_package_unavailable
          | :entitlement_scope_empty
          | :polo_policy_unavailable
          | :subscription_configuration_invalid
          | :unsupported_activation_policy
          | :unsupported_cycle_policy
          | :invalid_cycle_interval
          | :unsupported_subject_policy

  @spec prepare(module(), Scope.t(), OrderItem.t(), DateTime.t()) ::
          {:ok, ProvisioningPlan.t()} | {:error, error_reason()}
  def prepare(repo, %Scope{} = scope, %OrderItem{} = order_item, activated_at) do
    with {:ok, offering_version} <- lock_offering_version(repo, scope, order_item) do
      build_plan(repo, scope, offering_version, activated_at)
    end
  end

  @spec validate_for_checkout(module(), Scope.t(), ProductOfferingVersion.t(), DateTime.t()) ::
          :ok | {:error, error_reason()}
  def validate_for_checkout(
        repo,
        %Scope{} = scope,
        %ProductOfferingVersion{} = offering_version,
        activated_at
      ) do
    case build_plan(repo, scope, offering_version, activated_at) do
      {:ok, %ProvisioningPlan{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_plan(repo, scope, offering_version, activated_at) do
    with {:ok, configuration} <-
           lock_configuration(repo, scope, offering_version, activated_at),
         {:ok, benefits_during} <-
           CycleSchedule.bounds(
             repo,
             configuration.offering_version,
             configuration.polo,
             activated_at
           ),
         {:ok, allocation_specs} <-
           allocation_specs(repo, scope, configuration.items, activated_at) do
      {:ok,
       %ProvisioningPlan{
         configuration: configuration,
         benefits_during: benefits_during,
         allocation_specs: allocation_specs
       }}
    end
  end

  @spec materialize!(
          module(),
          Scope.t(),
          Order.t(),
          OrderItem.t(),
          Payment.t(),
          ProvisioningPlan.t(),
          DateTime.t()
        ) :: AccessContract.t()
  def materialize!(
        repo,
        %Scope{} = scope,
        %Order{} = order,
        %OrderItem{} = order_item,
        %Payment{} = payment,
        %ProvisioningPlan{} = plan,
        now
      ) do
    insert_subscription!(
      repo,
      scope,
      order,
      order_item,
      payment,
      plan,
      now
    )
  end

  @spec materialize_renewal!(
          module(),
          Scope.t(),
          AccessContract.t(),
          ProvisioningPlan.t(),
          DateTime.t()
        ) :: %{contract: AccessContract.t(), cycle: BenefitCycle.t(), allocations: [map()]}
  def materialize_renewal!(
        repo,
        %Scope{} = scope,
        %AccessContract{} = contract,
        %ProvisioningPlan{} = plan,
        now
      ) do
    last_cycle = lock_last_cycle!(repo, scope, contract.id)
    ensure_contiguous_renewal!(last_cycle, plan.benefits_during)

    last_cycle
    |> Ecto.Changeset.change(status: "closed", closed_at: now)
    |> repo.update!()

    cycle =
      %BenefitCycle{
        polo_id: scope.polo_id,
        access_contract_id: contract.id,
        benefit_package_version_id: plan.configuration.package_version.id,
        offering_package_assignment_id: plan.configuration.assignment.id,
        polo_policy_version_id: plan.configuration.policy.id,
        sequence: last_cycle.sequence + 1,
        benefits_during: plan.benefits_during,
        status: "active",
        activated_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    subject = insert_subject!(repo, scope, contract, cycle, now)
    allocations = insert_allocations!(repo, scope, subject, plan.allocation_specs, now)

    updated_contract =
      contract
      |> Ecto.Changeset.change(status: "active", updated_at: now)
      |> repo.update!()

    record_renewal!(repo, scope, updated_contract, cycle, allocations, now)

    %{contract: updated_contract, cycle: cycle, allocations: allocations}
  end

  defp lock_configuration(repo, scope, offering_version, activated_at) do
    with {:ok, polo} <- lock_polo(repo, scope.polo_id),
         :ok <- ensure_payment_activation(offering_version),
         {:ok, policy} <- lock_policy(repo, scope.polo_id, activated_at),
         {:ok, assignment, package_version} <-
           lock_assignment(repo, scope.polo_id, offering_version.id, activated_at),
         {:ok, items} <- lock_package_items(repo, scope.polo_id, package_version.id),
         :ok <- ensure_supported_subjects(items) do
      {:ok,
       %{
         polo: polo,
         offering_version: offering_version,
         policy: policy,
         assignment: assignment,
         package_version: package_version,
         items: items
       }}
    end
  end

  defp lock_polo(repo, polo_id) do
    case repo.one(from polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE") do
      %Polo{} = polo -> {:ok, polo}
      nil -> {:error, :subscription_configuration_invalid}
    end
  end

  defp lock_offering_version(repo, scope, order_item) do
    query =
      from version in ProductOfferingVersion,
        where:
          version.id == ^order_item.product_offering_version_id and
            version.polo_id == ^scope.polo_id,
        lock: "FOR SHARE"

    case repo.one(query) do
      %ProductOfferingVersion{} = version -> {:ok, version}
      nil -> {:error, :subscription_configuration_invalid}
    end
  end

  defp ensure_payment_activation(%ProductOfferingVersion{
         activation_policy: "payment_confirmation"
       }),
       do: :ok

  defp ensure_payment_activation(%ProductOfferingVersion{}),
    do: {:error, :unsupported_activation_policy}

  defp lock_policy(repo, polo_id, activated_at) do
    query =
      from policy in PoloPolicyVersion,
        where: policy.polo_id == ^polo_id,
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            policy.effective_during,
            type(^activated_at, :utc_datetime_usec)
          ),
        lock: "FOR SHARE"

    case repo.one(query) do
      %PoloPolicyVersion{} = policy -> {:ok, policy}
      nil -> {:error, :polo_policy_unavailable}
    end
  end

  defp lock_assignment(repo, polo_id, offering_version_id, activated_at) do
    query =
      from assignment in ProductOfferingPackageAssignment,
        join: package_version in BenefitPackageVersion,
        on:
          package_version.id == assignment.benefit_package_version_id and
            package_version.polo_id == assignment.polo_id,
        where:
          assignment.polo_id == ^polo_id and
            assignment.product_offering_version_id == ^offering_version_id,
        where: package_version.status == "published",
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            assignment.valid_during,
            type(^activated_at, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: {assignment, package_version}

    case repo.one(query) do
      {%ProductOfferingPackageAssignment{} = assignment,
       %BenefitPackageVersion{} = package_version} ->
        {:ok, assignment, package_version}

      nil ->
        {:error, :benefit_package_unavailable}
    end
  end

  defp lock_package_items(repo, polo_id, package_version_id) do
    items =
      BenefitPackageItem
      |> where(
        [item],
        item.polo_id == ^polo_id and item.benefit_package_version_id == ^package_version_id
      )
      |> order_by([item], asc: item.priority, asc: item.id)
      |> lock("FOR SHARE")
      |> repo.all()

    if items == [], do: {:error, :benefit_package_unavailable}, else: {:ok, items}
  end

  defp ensure_supported_subjects(items) do
    if Enum.all?(items, &(&1.subject_policy == "shared_contract")) do
      :ok
    else
      {:error, :unsupported_subject_policy}
    end
  end

  defp allocation_specs(repo, scope, items, activated_at) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, specs} ->
      case allocation_specs_for_item(repo, scope, item, activated_at) do
        {:ok, item_specs} -> {:cont, {:ok, [item_specs | specs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, nested_specs} -> {:ok, nested_specs |> Enum.reverse() |> List.flatten()}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp allocation_specs_for_item(repo, scope, %BenefitPackageItem{} = item, activated_at) do
    place_ids = eligible_place_ids(repo, scope.polo_id, item, activated_at)

    case {item.consumption_unit, place_ids} do
      {_kind, []} ->
        {:error, :entitlement_scope_empty}

      {"per_place", place_ids} ->
        {:ok, Enum.map(place_ids, &allocation_spec(item, &1))}

      {"shared_scope", _place_ids} ->
        {:ok, [allocation_spec(item, nil)]}

      {_unsupported, _place_ids} ->
        {:error, :subscription_configuration_invalid}
    end
  end

  defp eligible_place_ids(repo, polo_id, item, activated_at) do
    EntitlementScopePlace
    |> join(:inner, [scope_place], offer_place in BenefitOfferVersionPlace,
      as: :offer_place,
      on:
        offer_place.polo_id == scope_place.polo_id and
          offer_place.polo_place_id == scope_place.polo_place_id
    )
    |> join(:inner, [offer_place: offer_place], offer_version in BenefitOfferVersion,
      as: :offer_version,
      on:
        offer_version.id == offer_place.benefit_offer_version_id and
          offer_version.polo_id == offer_place.polo_id
    )
    |> join(:inner, [offer_version: offer_version], offer in BenefitOffer,
      as: :offer,
      on:
        offer.id == offer_version.benefit_offer_id and
          offer.polo_id == offer_version.polo_id
    )
    |> join(:inner, [scope_place], polo_place in PoloPlace,
      as: :polo_place,
      on:
        polo_place.id == scope_place.polo_place_id and
          polo_place.polo_id == scope_place.polo_id
    )
    |> join(:inner, [polo_place: polo_place], place in Place,
      as: :place,
      on: place.id == polo_place.place_id
    )
    |> where(
      [scope_place, offer_place: offer_place],
      scope_place.polo_id == ^polo_id and
        scope_place.entitlement_scope_id == ^item.entitlement_scope_id and
        offer_place.benefit_offer_version_id == ^item.benefit_offer_version_id
    )
    |> where([offer: offer], offer.status == "active")
    |> where([offer_version: offer_version], offer_version.status == "published")
    |> where(
      [offer_version: offer_version],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        offer_version.effective_during,
        type(^activated_at, :utc_datetime_usec)
      )
    )
    |> where([polo_place: polo_place], polo_place.status == "active")
    |> where(
      [polo_place: polo_place],
      fragment(
        "? @> (? AT TIME ZONE 'UTC')",
        polo_place.participation_during,
        type(^activated_at, :utc_datetime_usec)
      )
    )
    |> where([place: place], place.status == "active")
    |> order_by([scope_place], asc: scope_place.polo_place_id)
    |> lock("FOR SHARE")
    |> select([scope_place], scope_place.polo_place_id)
    |> repo.all()
  end

  defp allocation_spec(item, polo_place_id) do
    %{
      item: item,
      polo_place_id: polo_place_id,
      issued_units: item.allowance_per_cycle
    }
  end

  defp insert_subscription!(
         repo,
         scope,
         order,
         order_item,
         payment,
         plan,
         now
       ) do
    contract =
      insert_contract!(
        repo,
        scope,
        order,
        order_item,
        plan.configuration,
        now,
        now
      )

    cycle =
      insert_cycle!(
        repo,
        scope,
        contract,
        plan.configuration,
        plan.benefits_during,
        now,
        now
      )

    subject = insert_subject!(repo, scope, contract, cycle, now)
    allocations = insert_allocations!(repo, scope, subject, plan.allocation_specs, now)

    record_activation!(repo, scope, order, payment, contract, cycle, allocations, now)
    contract
  end

  defp lock_last_cycle!(repo, scope, contract_id) do
    BenefitCycle
    |> where(
      [cycle],
      cycle.polo_id == ^scope.polo_id and cycle.access_contract_id == ^contract_id
    )
    |> order_by([cycle], desc: cycle.sequence)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp ensure_contiguous_renewal!(last_cycle, next_period) do
    if last_cycle.status == "active" and
         last_cycle.benefits_during.upper == next_period.lower do
      :ok
    else
      raise "renewal cycle is not contiguous with the active contract cycle"
    end
  end

  defp record_renewal!(repo, scope, contract, cycle, allocations, now) do
    sequence = next_contract_event_sequence(repo, scope, contract.id)

    payload = %{
      "access_contract_id" => contract.id,
      "benefit_cycle_id" => cycle.id,
      "cycle_sequence" => cycle.sequence,
      "allocation_count" => length(allocations),
      "renewed_at" => DateTime.to_iso8601(now)
    }

    %ContractEvent{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      sequence: sequence,
      event_type: "renewed",
      actor_user_id: scope.actor_user_id,
      payload: payload,
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "access_contract",
      aggregate_id: contract.id,
      aggregate_version: sequence,
      event_type: "subscription.renewed",
      topic: "subscriptions.renewed",
      message_key: contract.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "subscription.renewed",
      resource_type: "access_contract",
      resource_id: contract.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp next_contract_event_sequence(repo, scope, contract_id) do
    current =
      ContractEvent
      |> where(
        [event],
        event.polo_id == ^scope.polo_id and event.access_contract_id == ^contract_id
      )
      |> repo.aggregate(:max, :sequence)

    (current || 0) + 1
  end

  defp insert_contract!(repo, scope, order, order_item, configuration, activated_at, now) do
    %AccessContract{
      polo_id: scope.polo_id,
      purchaser_user_id: order.purchaser_user_id,
      order_item_id: order_item.id,
      product_offering_version_id: order_item.product_offering_version_id,
      polo_policy_version_id: configuration.policy.id,
      status: "active",
      starts_at: activated_at,
      activated_at: activated_at,
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!()
  end

  defp insert_cycle!(repo, scope, contract, configuration, benefits_during, activated_at, now) do
    %BenefitCycle{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      benefit_package_version_id: configuration.package_version.id,
      offering_package_assignment_id: configuration.assignment.id,
      polo_policy_version_id: configuration.policy.id,
      sequence: 1,
      benefits_during: benefits_during,
      status: "active",
      activated_at: activated_at,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_subject!(repo, scope, contract, cycle, now) do
    %CycleEntitlementSubject{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      benefit_cycle_id: cycle.id,
      subject_kind: "contract",
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_allocations!(repo, scope, subject, allocation_specs, now) do
    Enum.map(allocation_specs, fn spec ->
      %EntitlementAllocation{
        polo_id: scope.polo_id,
        cycle_entitlement_subject_id: subject.id,
        benefit_package_item_id: spec.item.id,
        entitlement_scope_id: spec.item.entitlement_scope_id,
        polo_place_id: spec.polo_place_id,
        allocation_kind: spec.item.consumption_unit,
        issued_units: spec.issued_units,
        available_units: spec.issued_units,
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()
    end)
  end

  defp record_activation!(repo, scope, order, payment, contract, cycle, allocations, now) do
    payload = %{
      "access_contract_id" => contract.id,
      "order_id" => order.id,
      "payment_id" => payment.id,
      "benefit_cycle_id" => cycle.id,
      "allocation_count" => length(allocations),
      "activated_at" => DateTime.to_iso8601(contract.activated_at)
    }

    %ContractEvent{
      polo_id: scope.polo_id,
      access_contract_id: contract.id,
      sequence: 1,
      event_type: "activated",
      actor_user_id: scope.actor_user_id,
      payload: payload,
      occurred_at: now,
      inserted_at: now
    }
    |> repo.insert!()

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "access_contract",
      aggregate_id: contract.id,
      aggregate_version: 1,
      event_type: "subscription.activated",
      topic: "subscriptions.activated",
      message_key: contract.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "subscription.activated",
      resource_type: "access_contract",
      resource_id: contract.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}
end
