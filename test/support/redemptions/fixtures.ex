defmodule Clubeira.RedemptionsFixtures do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @id_names ~w(
    user
    city
    address
    place
    other_place
    device
    polo
    polo_policy
    polo_place
    other_polo_place
    validation_point
    validation_credential
    other_validation_point
    benefit_offer
    benefit_offer_version
    other_benefit_offer
    other_benefit_offer_version
    access_product
    access_product_version
    product_offering
    product_offering_version
    offering_price
    benefit_package
    benefit_package_version
    entitlement_scope
    invalid_entitlement_scope
    benefit_package_item
    package_assignment
    order
    order_item
    access_contract
    benefit_cycle
    entitlement_subject
    entitlement_allocation
    contract_redemption_device
    blackout
    availability_window
  )a

  @spec create!(keyword()) :: map()
  def create!(options \\ []) do
    ids =
      @id_names
      |> Map.new(&{&1, uuid7()})
      |> maybe_override_user(options)

    now = DateTime.utc_now(:microsecond)
    starts_at = DateTime.add(now, -3_600)
    ends_at = DateTime.add(now, 86_400)
    suffix = String.slice(String.replace(ids.polo, "-", ""), -12, 12)

    insert_global_rows!(ids, now, suffix, options)

    scope =
      Scope.new!(ids.polo,
        actor_user_id: ids.user,
        request_id: uuid7()
      )

    {:ok, :seeded} =
      Repo.transact_in_polo(scope, fn ->
        insert_tenant_rows!(ids, starts_at, ends_at, suffix, options)
        {:ok, :seeded}
      end)

    %{
      ids: ids,
      now: now,
      polo_slug: "polo-#{suffix}",
      scope: scope,
      request: build_request(ids)
    }
  end

  @spec request(map(), map()) :: map()
  def request(%{ids: ids}, overrides), do: build_request(ids, overrides)
  def request(%{ids: ids}), do: build_request(ids)

  @spec scoped_query!(map(), String.t(), list()) :: Postgrex.Result.t()
  def scoped_query!(fixture, sql, parameters \\ []) do
    {:ok, result} =
      Repo.transact_in_polo(fixture.scope, fn ->
        {:ok, Repo.query!(sql, Enum.map(parameters, &dump_parameter/1))}
      end)

    result
  end

  @spec insert_user!(Ecto.UUID.t(), String.t()) :: :ok
  def insert_user!(id, email) do
    insert!("users", %{id: id, email: email, status: "active"})
  end

  defp build_request(ids, overrides \\ %{}) do
    Map.merge(
      %{
        entitlement_allocation_id: ids.entitlement_allocation,
        validation_point_id: ids.validation_point,
        device_installation_id: ids.device,
        idempotency_key: "redeem-#{uuid7()}",
        request_nonce: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        request_context: %{"channel" => "test"}
      },
      overrides
    )
  end

  defp insert_global_rows!(ids, now, suffix, options) do
    if Keyword.get(options, :insert_user, true) do
      insert!("users", %{
        id: ids.user,
        email: Keyword.get(options, :user_email, "member-#{suffix}@example.test"),
        status: "active",
        authenticated_at: now
      })
    end

    insert!("cities", %{
      id: ids.city,
      country_code: "BR",
      subdivision_code: "BR-SP",
      external_code: "city-#{suffix}",
      name: "Cidade #{suffix}",
      timezone: "America/Sao_Paulo",
      status: "active"
    })

    insert!("addresses", %{
      id: ids.address,
      city_id: ids.city,
      street: "Rua do Resgate",
      number: "1",
      district: "Centro"
    })

    insert!("places", %{
      id: ids.place,
      city_id: ids.city,
      address_id: ids.address,
      slug: "place-#{suffix}",
      name: "Parceiro #{suffix}",
      timezone: "America/Sao_Paulo",
      status: Keyword.get(options, :place_status, "active")
    })

    insert!("places", %{
      id: ids.other_place,
      city_id: ids.city,
      address_id: ids.address,
      slug: "other-place-#{suffix}",
      name: "Outro parceiro #{suffix}",
      timezone: "America/Sao_Paulo",
      status: Keyword.get(options, :other_place_status, "active")
    })

    insert!("device_installations", %{
      id: ids.device,
      installation_token_hash: :crypto.hash(:sha256, ids.device),
      platform: "web",
      status: "active"
    })
  end

  defp insert_tenant_rows!(ids, starts_at, ends_at, suffix, options) do
    allocation_kind = Keyword.get(options, :allocation_kind, "per_place")
    available_units = Keyword.get(options, :available_units, 1)
    device_policy = Keyword.get(options, :device_policy, "any_authenticated")
    allocation_place_id = if allocation_kind == "per_place", do: ids.polo_place
    active = Factory.tstz_range(starts_at)
    bounded = Factory.tstz_range(starts_at, ends_at)
    participation_during = Keyword.get(options, :participation_during, active)

    insert!("polos", %{
      id: ids.polo,
      city_id: ids.city,
      name: "Polo #{suffix}",
      timezone: "America/Sao_Paulo",
      status: Keyword.get(options, :polo_status, "active")
    })

    insert!("polo_routes", %{
      polo_id: ids.polo,
      slug: "polo-#{suffix}"
    })

    insert!("polo_policy_versions", %{
      id: ids.polo_policy,
      polo_id: ids.polo,
      version: 1,
      effective_during: active,
      redemption_confirmation_mode: "member_only",
      redemption_device_policy: device_policy,
      max_authorized_devices: 3,
      delinquency_mode: "grace_period",
      delinquency_grace_days: 3,
      review_policy: Keyword.get(options, :review_policy, "verified_only"),
      published_at: starts_at
    })

    insert!("polo_places", %{
      id: ids.polo_place,
      city_id: ids.city,
      polo_id: ids.polo,
      place_id: ids.place,
      participation_during: participation_during,
      status: Keyword.get(options, :polo_place_status, "active")
    })

    insert!("validation_points", %{
      id: ids.validation_point,
      polo_id: ids.polo,
      polo_place_id: ids.polo_place,
      name: "Caixa principal",
      kind: "api",
      status: "active"
    })

    maybe_insert_validation_credential!(ids, active, options)

    if Keyword.get(options, :alternate_validation_place, false) do
      insert!("polo_places", %{
        id: ids.other_polo_place,
        city_id: ids.city,
        polo_id: ids.polo,
        place_id: ids.other_place,
        participation_during: Keyword.get(options, :other_participation_during, active),
        status: "active"
      })

      insert!("validation_points", %{
        id: ids.other_validation_point,
        polo_id: ids.polo,
        polo_place_id: ids.other_polo_place,
        name: "Caixa alternativo",
        kind: "api",
        status: "active"
      })
    end

    insert_catalog_rows!(ids, active, bounded, suffix, allocation_kind, options)
    insert_contract_rows!(ids, starts_at, bounded, suffix, options)
    insert_device_authorizations!(ids, active, options)

    insert!("cycle_entitlement_subjects", %{
      id: ids.entitlement_subject,
      polo_id: ids.polo,
      access_contract_id: ids.access_contract,
      benefit_cycle_id: ids.benefit_cycle,
      subject_kind: "contract"
    })

    insert!("entitlement_allocations", %{
      id: ids.entitlement_allocation,
      polo_id: ids.polo,
      cycle_entitlement_subject_id: ids.entitlement_subject,
      benefit_package_item_id: ids.benefit_package_item,
      entitlement_scope_id:
        if(Keyword.get(options, :invalid_entitlement_configuration, false),
          do: ids.invalid_entitlement_scope,
          else: ids.entitlement_scope
        ),
      polo_place_id: allocation_place_id,
      allocation_kind: allocation_kind,
      issued_units: max(available_units, 1),
      available_units: available_units
    })
  end

  defp insert_catalog_rows!(ids, active, bounded, suffix, allocation_kind, options) do
    offer_version_status = Keyword.get(options, :offer_version_status, "published")

    insert!("benefit_offers", %{
      id: ids.benefit_offer,
      polo_id: ids.polo,
      code: "offer-#{suffix}",
      name: "Benefício #{suffix}",
      benefit_kind: Keyword.get(options, :benefit_kind, "complimentary_item"),
      status: Keyword.get(options, :offer_status, "active")
    })

    insert!("benefit_offer_versions", %{
      id: ids.benefit_offer_version,
      polo_id: ids.polo,
      benefit_offer_id: ids.benefit_offer,
      version: 1,
      title: "Benefício de teste",
      description: "Descrição do benefício",
      terms: "Uso único",
      redemption_instructions: "Apresente no caixa",
      percentage_value: Keyword.get(options, :percentage_value),
      amount_value: Keyword.get(options, :amount_value),
      currency: Keyword.get(options, :currency),
      effective_during: Keyword.get(options, :offer_effective_during, active),
      status: offer_version_status,
      published_at:
        Keyword.get_lazy(options, :offer_published_at, fn ->
          if offer_version_status == "published", do: bounded.lower
        end)
    })

    insert!("benefit_packages", %{
      id: ids.benefit_package,
      polo_id: ids.polo,
      code: "package-#{suffix}",
      name: "Pacote #{suffix}",
      status: "active"
    })

    insert!("benefit_package_versions", %{
      id: ids.benefit_package_version,
      polo_id: ids.polo,
      benefit_package_id: ids.benefit_package,
      version: 1,
      name: "Pacote publicado",
      status: "published",
      published_at: bounded.lower
    })

    insert!("entitlement_scopes", %{
      id: ids.entitlement_scope,
      polo_id: ids.polo,
      benefit_package_version_id: ids.benefit_package_version,
      key: "scope-#{suffix}",
      name: "Estabelecimento",
      scope_kind: "place"
    })

    if Keyword.get(options, :invalid_entitlement_configuration, false) do
      insert!("entitlement_scopes", %{
        id: ids.invalid_entitlement_scope,
        polo_id: ids.polo,
        benefit_package_version_id: ids.benefit_package_version,
        key: "invalid-scope-#{suffix}",
        name: "Escopo incompatível",
        scope_kind: "place"
      })
    end

    insert!("benefit_package_items", %{
      id: ids.benefit_package_item,
      polo_id: ids.polo,
      benefit_package_version_id: ids.benefit_package_version,
      benefit_offer_version_id: ids.benefit_offer_version,
      entitlement_scope_id: ids.entitlement_scope,
      allowance_per_cycle: 1,
      consumption_unit: allocation_kind,
      subject_policy: "shared_contract",
      stacking_policy: "exclusive",
      priority: 100
    })

    if Keyword.get(options, :offer_available_at_place, true) do
      insert!("benefit_offer_version_places", %{
        polo_id: ids.polo,
        benefit_offer_version_id: ids.benefit_offer_version,
        polo_place_id: ids.polo_place
      })
    end

    if Keyword.get(options, :alternate_validation_place, false) do
      insert!("benefit_offer_version_places", %{
        polo_id: ids.polo,
        benefit_offer_version_id: ids.benefit_offer_version,
        polo_place_id: ids.other_polo_place
      })
    end

    if Keyword.get(options, :additional_offer, false) do
      insert!("benefit_offers", %{
        id: ids.other_benefit_offer,
        polo_id: ids.polo,
        code: "other-offer-#{suffix}",
        name: "Outro benefício #{suffix}",
        benefit_kind: "complimentary_item",
        status: "active"
      })

      insert!("benefit_offer_versions", %{
        id: ids.other_benefit_offer_version,
        polo_id: ids.polo,
        benefit_offer_id: ids.other_benefit_offer,
        version: 1,
        title: "Outro benefício de teste",
        description: "Outra descrição do benefício",
        terms: "Uso único",
        redemption_instructions: "Apresente no caixa",
        effective_during: active,
        status: "published",
        published_at: bounded.lower
      })

      insert!("benefit_offer_version_places", %{
        polo_id: ids.polo,
        benefit_offer_version_id: ids.other_benefit_offer_version,
        polo_place_id: ids.polo_place
      })
    end

    insert!("entitlement_scope_places", %{
      polo_id: ids.polo,
      entitlement_scope_id: ids.entitlement_scope,
      polo_place_id: ids.polo_place
    })

    if Keyword.get(options, :blackout, false) do
      insert!("benefit_offer_blackout_periods", %{
        id: ids.blackout,
        polo_id: ids.polo,
        benefit_offer_version_id: ids.benefit_offer_version,
        blackout_during: bounded,
        reason: "Janela bloqueada para teste"
      })
    end

    if Keyword.get(options, :outside_availability_window, false) do
      insert!("benefit_offer_availability_windows", %{
        id: ids.availability_window,
        polo_id: ids.polo,
        benefit_offer_version_id: ids.benefit_offer_version,
        weekday: next_weekday(),
        starts_at_local: ~T[00:00:00],
        ends_at_local: ~T[23:59:59]
      })
    end

    insert_product_rows!(ids, active, suffix)
  end

  defp insert_product_rows!(ids, active, suffix) do
    insert!("access_products", %{
      id: ids.access_product,
      polo_id: ids.polo,
      code: "access-#{suffix}",
      name: "Clube #{suffix}",
      status: "active"
    })

    insert!("access_product_versions", %{
      id: ids.access_product_version,
      polo_id: ids.polo,
      access_product_id: ids.access_product,
      version: 1,
      name: "Plano publicado",
      description: "Plano de teste",
      status: "published",
      published_at: active.lower
    })

    insert!("product_offerings", %{
      id: ids.product_offering,
      polo_id: ids.polo,
      access_product_version_id: ids.access_product_version,
      code: "offering-#{suffix}",
      scope_kind: "evergreen",
      sales_channel: "direct",
      status: "active"
    })

    insert!("product_offering_versions", %{
      id: ids.product_offering_version,
      polo_id: ids.polo,
      product_offering_id: ids.product_offering,
      version: 1,
      name: "Oferta publicada",
      description: "Oferta de teste",
      effective_during: active,
      activation_policy: "payment_confirmation",
      cycle_policy: "explicit",
      renewal_policy: "none",
      minimum_beneficiaries: 1,
      maximum_beneficiaries: 1,
      status: "published",
      published_at: active.lower
    })

    insert!("offering_prices", %{
      id: ids.offering_price,
      polo_id: ids.polo,
      product_offering_version_id: ids.product_offering_version,
      price_key: "default",
      currency: "BRL",
      amount: Decimal.new("10.00"),
      billing_model: "one_time",
      installments: 1,
      valid_during: active
    })

    insert!("product_offering_package_assignments", %{
      id: ids.package_assignment,
      polo_id: ids.polo,
      product_offering_version_id: ids.product_offering_version,
      benefit_package_version_id: ids.benefit_package_version,
      valid_during: active
    })
  end

  defp insert_contract_rows!(ids, starts_at, bounded, suffix, options) do
    insert!("orders", %{
      id: ids.order,
      polo_id: ids.polo,
      purchaser_user_id: ids.user,
      order_number: "order-#{suffix}",
      idempotency_key: "order-#{suffix}",
      currency: "BRL",
      subtotal_amount: Decimal.new("10.00"),
      discount_amount: Decimal.new("0.00"),
      total_amount: Decimal.new("10.00"),
      status: "paid",
      placed_at: starts_at
    })

    insert!("order_items", %{
      id: ids.order_item,
      polo_id: ids.polo,
      order_id: ids.order,
      product_offering_version_id: ids.product_offering_version,
      offering_price_id: ids.offering_price,
      quantity: 1,
      unit_amount: Decimal.new("10.00"),
      total_amount: Decimal.new("10.00")
    })

    insert!("access_contracts", %{
      id: ids.access_contract,
      polo_id: ids.polo,
      purchaser_user_id: ids.user,
      order_item_id: ids.order_item,
      product_offering_version_id: ids.product_offering_version,
      polo_policy_version_id: ids.polo_policy,
      status: Keyword.get(options, :contract_status, "active"),
      starts_at: starts_at,
      activated_at: starts_at
    })

    insert!("benefit_cycles", %{
      id: ids.benefit_cycle,
      polo_id: ids.polo,
      access_contract_id: ids.access_contract,
      benefit_package_version_id: ids.benefit_package_version,
      offering_package_assignment_id: ids.package_assignment,
      polo_policy_version_id: ids.polo_policy,
      sequence: 1,
      benefits_during: bounded,
      status: Keyword.get(options, :cycle_status, "active"),
      activated_at: starts_at
    })
  end

  defp insert_device_authorizations!(ids, active, options) do
    if Keyword.get(options, :authorize_user_device, true) do
      insert!("user_device_authorizations", %{
        user_id: ids.user,
        device_installation_id: ids.device,
        status: "active",
        authorized_at: active.lower
      })
    end

    if Keyword.get(options, :authorize_device, false) do
      insert!("contract_redemption_devices", %{
        id: ids.contract_redemption_device,
        polo_id: ids.polo,
        access_contract_id: ids.access_contract,
        device_installation_id: ids.device,
        valid_during: active,
        status: "active"
      })
    end
  end

  defp maybe_insert_validation_credential!(ids, active, options) do
    case Keyword.get(options, :validation_credential_secret) do
      nil ->
        :ok

      secret ->
        {:ok, decoded_secret} = Base.url_decode64(secret, padding: false)

        insert!("validation_credentials", %{
          id: ids.validation_credential,
          polo_id: ids.polo,
          validation_point_id: ids.validation_point,
          version: 1,
          kind: "manual_code",
          secret_hash: :crypto.hash(:sha256, decoded_secret),
          valid_during: active,
          status: "active"
        })
    end
  end

  defp insert!(table, attributes) do
    dumped_attributes =
      Map.new(attributes, fn {field, value} ->
        {field, dump_field(field, value)}
      end)

    assert_inserted!(table, Repo.insert_all(table, [dumped_attributes]))
  end

  defp next_weekday do
    %{rows: [[weekday]]} =
      Repo.query!("""
      SELECT EXTRACT(
        ISODOW FROM statement_timestamp() AT TIME ZONE 'America/Sao_Paulo'
      )::smallint
      """)

    rem(weekday, 7) + 1
  end

  defp assert_inserted!(_table, {1, nil}), do: :ok

  defp assert_inserted!(table, result) do
    raise "could not insert redemption fixture row into #{table}: #{inspect(result)}"
  end

  defp dump_field(field, value) when is_binary(value) do
    if field == :id or String.ends_with?(Atom.to_string(field), "_id") do
      Ecto.UUID.dump!(value)
    else
      value
    end
  end

  defp dump_field(_field, value), do: value

  defp dump_parameter(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Ecto.UUID.dump!(uuid)
      :error -> value
    end
  end

  defp dump_parameter(value), do: value

  defp maybe_override_user(ids, options) do
    case Keyword.fetch(options, :user_id) do
      {:ok, user_id} -> Map.put(ids, :user, Ecto.UUID.cast!(user_id))
      :error -> ids
    end
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
