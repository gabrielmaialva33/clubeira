defmodule Clubeira.Subscriptions.ProductOfferingPublisher do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessProduct
  alias Clubeira.Subscriptions.AccessProductVersion
  alias Clubeira.Subscriptions.BenefitPackage
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.EntitlementScope
  alias Clubeira.Subscriptions.EntitlementScopePlace
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingPackageAssignment
  alias Clubeira.Subscriptions.ProductOfferingPublishRequest
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope
  alias Clubeira.Types.TstzRange

  @idempotency_scope "subscriptions.publish_product_offering"
  @graph_savepoint "publish_product_offering_graph"
  @replay_reasons %{
    "benefit_configuration_unavailable" => :benefit_configuration_unavailable,
    "benefit_offer_version_not_found" => :benefit_offer_version_not_found,
    "product_offering_code_taken" => :product_offering_code_taken
  }

  @type result :: %{String.t() => term()}
  @type error ::
          atom()
          | {:tenant_scope_mismatch, :polo_id | :actor_user_id | :request_id}
          | Ecto.Changeset.t()

  @spec publish(Scope.t(), map()) :: {:ok, result()} | {:error, error()}
  def publish(%Scope{actor_user_id: nil}, _attributes),
    do: {:error, :partner_admin_required}

  def publish(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- ProductOfferingPublishRequest.new(attributes) do
      scope
      |> transact_publish(request)
      |> unwrap_transaction()
    end
  end

  def publish(_scope, _attributes), do: {:error, :partner_admin_required}

  defp transact_publish(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        reserve_publish(repo, scope, request, now)
      end
    end)
  end

  defp reserve_publish(repo, scope, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} ->
        publish_new!(repo, scope, request, idempotency_id, now)

      {:replay, key} ->
        {:ok, replay(key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_new!(repo, scope, request, key_id, now) do
    case fetch_benefits(repo, scope, request) do
      {:ok, benefits} ->
        publish_fetched_graph(repo, scope, benefits, request, key_id, now)

      {:error, reason}
      when reason in [:benefit_offer_version_not_found, :benefit_configuration_unavailable] ->
        {:ok, reject!(repo, scope, key_id, reason, now)}
    end
  end

  defp publish_fetched_graph(repo, scope, benefits, request, key_id, now) do
    case publish_graph(repo, scope, benefits, request, key_id, now) do
      {:ok, result} ->
        {:ok, result}

      {:error, :product_offering_code_taken} ->
        {:ok, reject!(repo, scope, key_id, :product_offering_code_taken, now)}

      {:error, %Ecto.Changeset{} = changeset} ->
        repo.rollback(changeset)
    end
  end

  defp publish_graph(repo, scope, benefits, request, key_id, now) do
    repo.query!("SAVEPOINT #{@graph_savepoint}")

    try do
      access_product =
        repo
        |> insert_access_product(scope, request, now)
        |> unwrap_code_identity!()

      result =
        complete_publication!(repo, scope, access_product, benefits, request, key_id, now)

      repo.query!("RELEASE SAVEPOINT #{@graph_savepoint}")
      {:ok, result}
    catch
      :throw, {:product_offering_graph_error, reason} ->
        repo.query!("ROLLBACK TO SAVEPOINT #{@graph_savepoint}")
        repo.query!("RELEASE SAVEPOINT #{@graph_savepoint}")
        {:error, reason}
    end
  end

  defp insert_access_product(repo, scope, request, now) do
    %AccessProduct{
      polo_id: scope.polo_id,
      code: request.code,
      name: request.name,
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:code, name: :access_products_polo_id_code_index)
    |> repo.insert(mode: :savepoint)
    |> classify_code_insert("access_products_polo_id_code_index")
  end

  defp classify_code_insert({:error, %Ecto.Changeset{} = changeset}, constraint_name) do
    if code_conflict?(changeset, constraint_name),
      do: {:error, :product_offering_code_taken},
      else: {:error, changeset}
  end

  defp classify_code_insert(result, _constraint_name), do: result

  defp code_conflict?(changeset, constraint_name) do
    Enum.any?(changeset.errors, fn
      {:code, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] == constraint_name

      _other ->
        false
    end)
  end

  defp complete_publication!(repo, scope, access_product, benefits, request, key_id, now) do
    effective_during = effective_range(request)

    access_product_version =
      %AccessProductVersion{
        polo_id: scope.polo_id,
        access_product_id: access_product.id,
        version: 1,
        name: request.name,
        description: request.description,
        status: "published",
        published_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    product_offering =
      insert_product_offering!(repo, scope, access_product_version, request, now)

    product_offering_version =
      %ProductOfferingVersion{
        polo_id: scope.polo_id,
        product_offering_id: product_offering.id,
        version: 1,
        name: request.name,
        description: request.description,
        effective_during: effective_during,
        activation_policy: "payment_confirmation",
        cycle_policy: request.cycle_policy,
        cycle_interval_unit: request.cycle_interval_unit,
        cycle_interval_count: request.cycle_interval_count,
        renewal_policy: "none",
        minimum_beneficiaries: 1,
        maximum_beneficiaries: 1,
        status: "published",
        published_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    price =
      %OfferingPrice{
        polo_id: scope.polo_id,
        product_offering_version_id: product_offering_version.id,
        price_key: "default",
        currency: request.currency,
        amount: request.amount,
        billing_model: "subscription",
        billing_interval_unit: request.cycle_interval_unit,
        billing_interval_count: request.cycle_interval_count,
        installments: 1,
        valid_during: effective_during,
        inserted_at: now
      }
      |> repo.insert!()

    package = insert_benefit_package!(repo, scope, request, now)

    package_version =
      %BenefitPackageVersion{
        polo_id: scope.polo_id,
        benefit_package_id: package.id,
        version: 1,
        name: request.name,
        status: "published",
        published_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    entitlement_scope =
      insert_entitlement_scope!(repo, scope, package_version, benefits, now)

    insert_scope_places!(repo, scope, entitlement_scope, benefits, now)

    items =
      insert_package_items!(repo, scope, package_version, entitlement_scope, benefits, now)

    assignment =
      %ProductOfferingPackageAssignment{
        polo_id: scope.polo_id,
        product_offering_version_id: product_offering_version.id,
        benefit_package_version_id: package_version.id,
        valid_during: effective_during,
        inserted_at: now
      }
      |> repo.insert!()

    result =
      response_data(%{
        access_product: access_product,
        access_product_version: access_product_version,
        product_offering: product_offering,
        product_offering_version: product_offering_version,
        price: price,
        package: package,
        package_version: package_version,
        assignment: assignment,
        benefits: benefits,
        items: items
      })

    record_publication!(repo, scope, result, now)
    Idempotency.complete!(repo, key_id, "product_offering", product_offering.id, result, now)

    {:accepted, result}
  end

  defp insert_product_offering!(repo, scope, access_product_version, request, now) do
    result =
      %ProductOffering{
        polo_id: scope.polo_id,
        access_product_version_id: access_product_version.id,
        code: request.code,
        scope_kind: "evergreen",
        sales_channel: "direct",
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:code,
        name: :product_offerings_polo_id_code_index
      )
      |> repo.insert(mode: :savepoint)
      |> classify_code_insert("product_offerings_polo_id_code_index")

    unwrap_code_identity!(result)
  end

  defp insert_benefit_package!(repo, scope, request, now) do
    result =
      %BenefitPackage{
        polo_id: scope.polo_id,
        code: request.code,
        name: request.name,
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:code,
        name: :benefit_packages_polo_id_code_index
      )
      |> repo.insert(mode: :savepoint)
      |> classify_code_insert("benefit_packages_polo_id_code_index")

    unwrap_code_identity!(result)
  end

  defp unwrap_code_identity!({:ok, identity}), do: identity

  defp unwrap_code_identity!({:error, reason}),
    do: throw({:product_offering_graph_error, reason})

  defp insert_entitlement_scope!(repo, scope, package_version, benefits, now) do
    scope_kind = if distinct_place_ids(benefits) |> length() == 1, do: "place", else: "custom"

    %EntitlementScope{
      polo_id: scope.polo_id,
      benefit_package_version_id: package_version.id,
      key: "included-benefits",
      name: "Benefícios incluídos",
      scope_kind: scope_kind,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp insert_scope_places!(repo, scope, entitlement_scope, benefits, now) do
    Enum.each(distinct_place_ids(benefits), fn polo_place_id ->
      %EntitlementScopePlace{
        polo_id: scope.polo_id,
        entitlement_scope_id: entitlement_scope.id,
        polo_place_id: polo_place_id,
        inserted_at: now
      }
      |> repo.insert!()
    end)
  end

  defp insert_package_items!(repo, scope, package_version, entitlement_scope, benefits, now) do
    benefits
    |> Enum.with_index(1)
    |> Enum.map(fn {benefit, index} ->
      %BenefitPackageItem{
        polo_id: scope.polo_id,
        benefit_package_version_id: package_version.id,
        benefit_offer_version_id: benefit.request.benefit_offer_version_id,
        entitlement_scope_id: entitlement_scope.id,
        allowance_per_cycle: benefit.request.allowance_per_cycle,
        consumption_unit: benefit.request.consumption_unit,
        subject_policy: "shared_contract",
        stacking_policy: "exclusive",
        priority: index * 100,
        inserted_at: now
      }
      |> repo.insert!()
    end)
  end

  defp fetch_benefits(repo, scope, request) do
    version_ids = Enum.map(request.benefits, & &1.benefit_offer_version_id)
    effective_during = effective_range(request)

    versions =
      BenefitOfferVersion
      |> join(:inner, [version], offer in BenefitOffer,
        on: offer.id == version.benefit_offer_id and offer.polo_id == version.polo_id
      )
      |> where([version], version.polo_id == ^scope.polo_id and version.id in ^version_ids)
      |> order_by([version], asc: version.id)
      |> lock("FOR SHARE")
      |> select([version, offer], {
        version.id,
        version.status,
        offer.status,
        fragment("? @> ?", version.effective_during, type(^effective_during, TstzRange))
      })
      |> repo.all()

    cond do
      MapSet.new(versions, &elem(&1, 0)) != MapSet.new(version_ids) ->
        {:error, :benefit_offer_version_not_found}

      Enum.all?(versions, &available_benefit_version?/1) ->
        fetch_benefit_places(repo, scope, request, effective_during)

      true ->
        {:error, :benefit_configuration_unavailable}
    end
  end

  defp available_benefit_version?({_id, "published", "active", true}), do: true
  defp available_benefit_version?(_version), do: false

  defp fetch_benefit_places(repo, scope, request, effective_during) do
    version_ids = Enum.map(request.benefits, & &1.benefit_offer_version_id)

    places_by_version =
      BenefitOfferVersionPlace
      |> join(:inner, [offer_place], polo_place in PoloPlace,
        on:
          polo_place.id == offer_place.polo_place_id and
            polo_place.polo_id == offer_place.polo_id
      )
      |> join(:inner, [_offer_place, polo_place], place in Place,
        on: place.id == polo_place.place_id
      )
      |> where(
        [offer_place],
        offer_place.polo_id == ^scope.polo_id and
          offer_place.benefit_offer_version_id in ^version_ids
      )
      |> where(
        [_offer_place, polo_place, place],
        polo_place.status == "active" and place.status == "active"
      )
      |> where(
        [_offer_place, polo_place],
        fragment("? @> ?", polo_place.participation_during, type(^effective_during, TstzRange))
      )
      |> order_by([offer_place],
        asc: offer_place.benefit_offer_version_id,
        asc: offer_place.polo_place_id
      )
      |> lock("FOR SHARE")
      |> select(
        [offer_place],
        {offer_place.benefit_offer_version_id, offer_place.polo_place_id}
      )
      |> repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    benefits =
      Enum.map(request.benefits, fn benefit_request ->
        %{
          request: benefit_request,
          polo_place_ids: Map.get(places_by_version, benefit_request.benefit_offer_version_id, [])
        }
      end)

    if Enum.all?(benefits, &(&1.polo_place_ids != [])),
      do: {:ok, benefits},
      else: {:error, :benefit_configuration_unavailable}
  end

  defp distinct_place_ids(benefits) do
    benefits
    |> Enum.flat_map(& &1.polo_place_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp response_data(graph) do
    items_by_version = Map.new(graph.items, &{&1.benefit_offer_version_id, &1})

    %{
      "access_product" => %{
        "id" => graph.access_product.id,
        "version_id" => graph.access_product_version.id,
        "code" => graph.access_product.code,
        "name" => graph.access_product.name
      },
      "product_offering" => %{
        "id" => graph.product_offering.id,
        "version_id" => graph.product_offering_version.id,
        "version" => graph.product_offering_version.version,
        "status" => graph.product_offering_version.status,
        "activation_policy" => graph.product_offering_version.activation_policy,
        "renewal_policy" => graph.product_offering_version.renewal_policy,
        "cycle" => %{
          "policy" => graph.product_offering_version.cycle_policy,
          "interval_unit" => graph.product_offering_version.cycle_interval_unit,
          "interval_count" => graph.product_offering_version.cycle_interval_count
        }
      },
      "price" => %{
        "id" => graph.price.id,
        "key" => graph.price.price_key,
        "currency" => graph.price.currency,
        "amount" => Decimal.to_string(graph.price.amount, :normal),
        "billing_model" => graph.price.billing_model
      },
      "benefit_package" => %{
        "id" => graph.package.id,
        "version_id" => graph.package_version.id,
        "version" => graph.package_version.version,
        "assignment_id" => graph.assignment.id,
        "item_count" => length(graph.items)
      },
      "benefits" =>
        Enum.map(graph.benefits, fn benefit ->
          item = Map.fetch!(items_by_version, benefit.request.benefit_offer_version_id)

          %{
            "benefit_offer_version_id" => benefit.request.benefit_offer_version_id,
            "benefit_package_item_id" => item.id,
            "allowance_per_cycle" => item.allowance_per_cycle,
            "consumption_unit" => item.consumption_unit,
            "polo_place_ids" => benefit.polo_place_ids
          }
        end)
    }
  end

  defp record_publication!(repo, scope, result, now) do
    offering = result["product_offering"]
    package = result["benefit_package"]

    payload = %{
      "access_product_id" => result["access_product"]["id"],
      "access_product_version_id" => result["access_product"]["version_id"],
      "product_offering_id" => offering["id"],
      "product_offering_version_id" => offering["version_id"],
      "offering_price_id" => result["price"]["id"],
      "benefit_package_id" => package["id"],
      "benefit_package_version_id" => package["version_id"],
      "benefit_count" => package["item_count"],
      "version" => offering["version"],
      "published_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "product_offering",
      aggregate_id: offering["id"],
      aggregate_version: offering["version"],
      event_type: "product_offering.published",
      topic: "subscriptions.product_offerings.published",
      message_key: offering["id"],
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "product_offering.published",
      resource_type: "product_offering",
      resource_id: offering["id"],
      metadata: payload,
      occurred_at: now
    })
  end

  defp reject!(repo, scope, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now,
      response_status: failure_status(reason)
    )

    Audit.record_tenant!(repo, scope, %{
      action: "product_offering.publication_rejected",
      resource_type: "product_offering_publication",
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp replay(%Key{
         status: "completed",
         response_status: 201,
         resource_type: "product_offering",
         response_body: response_body
       })
       when is_map(response_body),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key), do: raise("invalid persisted product offering response: #{inspect(key)}")

  defp failure_status(:benefit_offer_version_not_found), do: 404
  defp failure_status(:benefit_configuration_unavailable), do: 409
  defp failure_status(:product_offering_code_taken), do: 409

  defp request_hash(scope, request) do
    benefits =
      Enum.map(request.benefits, fn benefit ->
        {
          benefit.benefit_offer_version_id,
          benefit.allowance_per_cycle,
          benefit.consumption_unit
        }
      end)

    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.code,
      request.name,
      request.description,
      request.cycle_policy,
      request.cycle_interval_unit,
      request.cycle_interval_count,
      request.effective_from,
      request.effective_until,
      request.currency,
      request.amount,
      benefits
    })
  end

  defp effective_range(request) do
    %Postgrex.Range{
      lower: request.effective_from,
      upper: request.effective_until || :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp fetch_active_polo(repo, polo_id) do
    polo =
      Polo
      |> where([polo], polo.id == ^polo_id)
      |> lock("FOR SHARE")
      |> repo.one()

    case polo do
      %Polo{status: "active"} -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
