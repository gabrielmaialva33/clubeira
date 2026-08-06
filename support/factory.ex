defmodule Clubeira.Factory do
  @moduledoc """
  Shared factory entrypoint for development data and tests.

  Canonical seeds pass explicit deterministic values to these factories.
  Reserve Faker for presentation data that is irrelevant to behavior, and pass
  required associations explicitly when a table has composite scope rules.
  """

  use ExMachina.Ecto, repo: Clubeira.Repo

  alias Clubeira.Accounts.User
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Catalog.Edition
  alias Clubeira.Catalog.EditionPlace
  alias Clubeira.Directory.Address
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.BrandOwnership
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationIdentifier
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceBrand
  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Directory.PoloPlaceProfileCategory
  alias Clubeira.Factory.Brazil
  alias Clubeira.Legal.Acceptance
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Security.IdentifierVault
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.AccessProduct
  alias Clubeira.Subscriptions.AccessProductVersion
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.BenefitPackage
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementScope
  alias Clubeira.Subscriptions.EntitlementScopePlace
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingPackageAssignment
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Faker.Person.PtBr

  @default_range_start ~U[2026-01-01 00:00:00Z]
  @default_range_end ~U[2100-01-01 00:00:00Z]

  def user_factory do
    %User{email: unique_email(), status: "active"}
  end

  def legal_document_factory do
    number = sequence(:legal_document, & &1)

    %Document{
      code: "consumer-terms-#{number}",
      document_kind: "terms_of_service",
      audience: "consumer",
      status: "active"
    }
  end

  def legal_document_version_factory do
    %DocumentVersion{
      version: 1,
      locale: "pt-BR",
      content_uri: "/legal/demo-consumer-terms-v1.txt",
      content_sha256: :crypto.hash(:sha256, "demo consumer terms v1"),
      effective_during: tstz_range(@default_range_start),
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def legal_acceptance_factory do
    now = timestamp()

    %Acceptance{
      accepted_at: now,
      evidence: %{"source" => "factory"},
      inserted_at: now
    }
  end

  def city_factory do
    number = sequence(:city, & &1)

    %City{
      country_code: "BR",
      subdivision_code: "BR-SP",
      external_code: "demo-city-#{number}",
      name: "Cidade Demo #{number}",
      timezone: "America/Sao_Paulo",
      status: "active"
    }
  end

  def organization_factory do
    number = sequence(:organization, & &1)

    %Organization{
      kind: "legal_entity",
      legal_name: "Organização Demo #{number} Ltda.",
      trade_name: "Organização Demo #{number}",
      country_code: "BR",
      status: "active"
    }
  end

  def organization_identifier_factory do
    now = timestamp()
    sealed = IdentifierVault.seal("cnpj", cnpj())

    %OrganizationIdentifier{
      kind: "cnpj",
      ciphertext: sealed.ciphertext,
      lookup_token: sealed.lookup_token,
      key_version: sealed.key_version,
      verified_at: now,
      inserted_at: now
    }
  end

  def brand_factory do
    number = sequence(:brand, & &1)

    %Brand{
      slug: "marca-demo-#{number}",
      name: "Marca Demo #{number}",
      status: "active"
    }
  end

  def address_factory do
    number = sequence(:address, & &1)

    %Address{
      street: "Rua de Demonstração #{number}",
      number: Integer.to_string(number),
      district: "Centro"
    }
  end

  def place_factory do
    number = sequence(:place, & &1)

    %Place{
      slug: "unidade-demo-#{number}",
      name: "Unidade Demo #{number}",
      timezone: "America/Sao_Paulo",
      status: "active"
    }
  end

  def place_category_factory do
    number = sequence(:place_category, & &1)

    %PlaceCategory{
      key: "category-#{number}",
      name: "Categoria #{number}",
      status: "active",
      display_order: number
    }
  end

  def brand_ownership_factory do
    %BrandOwnership{
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def place_brand_factory do
    %PlaceBrand{
      role: "primary",
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def place_operator_factory do
    %PlaceOperator{
      role: "operator",
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def polo_factory do
    number = sequence(:polo, & &1)

    %Polo{
      name: "Polo Demo #{number}",
      timezone: "America/Sao_Paulo",
      status: "active"
    }
  end

  def polo_route_factory do
    %PoloRoute{slug: unique_slug("polo")}
  end

  def polo_role_factory do
    number = sequence(:polo_role, & &1)

    %PoloRole{
      key: "role-#{number}",
      name: "Papel #{number}",
      status: "active"
    }
  end

  def polo_membership_factory do
    %PoloMembership{
      valid_during: tstz_range(@default_range_start),
      status: "active"
    }
  end

  def polo_membership_role_factory do
    %PoloMembershipRole{inserted_at: timestamp()}
  end

  def polo_policy_version_factory do
    %PoloPolicyVersion{
      version: 1,
      effective_during: tstz_range(@default_range_start),
      redemption_confirmation_mode: "two_party",
      redemption_device_policy: "authorized_devices",
      max_authorized_devices: 3,
      delinquency_mode: "grace_period",
      delinquency_grace_days: 3,
      review_policy: "verified_only",
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def polo_place_factory do
    %PoloPlace{
      participation_during: tstz_range(@default_range_start),
      status: "active"
    }
  end

  def polo_place_profile_factory do
    %PoloPlaceProfile{
      public_email: unique_email(),
      public_phone: "+5511999990000",
      revision: 1
    }
  end

  def polo_place_profile_category_factory do
    %PoloPlaceProfileCategory{inserted_at: timestamp()}
  end

  def polo_place_opening_period_factory do
    %PoloPlaceOpeningPeriod{
      kind: "weekly",
      weekday: 1,
      opens_at: ~T[09:00:00],
      closes_at: ~T[18:00:00],
      closes_next_day: false
    }
  end

  def edition_factory do
    number = sequence(:edition, & &1)

    %Edition{
      code: "demo-#{number}",
      name: "Edição Demo #{number}",
      sales_during: tstz_range(@default_range_start, @default_range_end),
      benefits_during: tstz_range(@default_range_start, @default_range_end),
      status: "active"
    }
  end

  def edition_place_factory do
    %EditionPlace{inserted_at: timestamp()}
  end

  def benefit_offer_factory do
    number = sequence(:benefit_offer, & &1)

    %BenefitOffer{
      code: "benefit-#{number}",
      name: "Benefício Demo #{number}",
      benefit_kind: "complimentary_item",
      status: "active"
    }
  end

  def benefit_offer_version_factory do
    %BenefitOfferVersion{
      version: 1,
      title: "Benefício publicado",
      description: "Descrição do benefício",
      terms: "Um uso por ciclo",
      redemption_instructions: "Apresente no estabelecimento",
      effective_during: tstz_range(@default_range_start),
      status: "published",
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def benefit_offer_version_place_factory do
    %BenefitOfferVersionPlace{inserted_at: timestamp()}
  end

  def access_product_factory do
    number = sequence(:access_product, & &1)

    %AccessProduct{
      code: "clube-#{number}",
      name: "Clube Demo #{number}",
      status: "active"
    }
  end

  def access_product_version_factory do
    %AccessProductVersion{
      version: 1,
      name: "Plano publicado",
      description: "Assinatura demo",
      status: "published",
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def product_offering_factory do
    %ProductOffering{
      code: unique_slug("oferta"),
      scope_kind: "evergreen",
      sales_channel: "direct",
      status: "active"
    }
  end

  def product_offering_version_factory do
    %ProductOfferingVersion{
      version: 1,
      name: "Assinatura mensal",
      description: "Renovação mensal com um uso por benefício e ciclo",
      effective_during: tstz_range(@default_range_start),
      activation_policy: "payment_confirmation",
      cycle_policy: "calendar",
      cycle_interval_unit: "month",
      cycle_interval_count: 1,
      renewal_policy: "automatic",
      minimum_beneficiaries: 1,
      maximum_beneficiaries: 1,
      status: "published",
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def offering_price_factory do
    %OfferingPrice{
      price_key: "default",
      currency: "BRL",
      amount: Decimal.new("29.90"),
      billing_model: "subscription",
      billing_interval_unit: "month",
      billing_interval_count: 1,
      installments: 1,
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def benefit_package_factory do
    %BenefitPackage{code: unique_slug("pacote"), name: "Pacote Demo", status: "active"}
  end

  def benefit_package_version_factory do
    %BenefitPackageVersion{
      version: 1,
      name: "Pacote publicado",
      status: "published",
      published_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def entitlement_scope_factory do
    %EntitlementScope{
      key: unique_slug("escopo"),
      name: "Parceiros participantes",
      scope_kind: "place",
      inserted_at: timestamp()
    }
  end

  def entitlement_scope_place_factory do
    %EntitlementScopePlace{inserted_at: timestamp()}
  end

  def benefit_package_item_factory do
    %BenefitPackageItem{
      allowance_per_cycle: 1,
      consumption_unit: "per_place",
      subject_policy: "shared_contract",
      stacking_policy: "exclusive",
      priority: 100,
      inserted_at: timestamp()
    }
  end

  def product_offering_package_assignment_factory do
    %ProductOfferingPackageAssignment{
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def payment_provider_factory do
    number = sequence(:payment_provider, & &1)

    %PaymentProvider{
      code: "provider-#{number}",
      name: "Provedor Demo #{number}",
      status: "active"
    }
  end

  def merchant_account_factory do
    number = sequence(:merchant_account, & &1)

    %MerchantAccount{
      kind: "consumer",
      name: "Conta consumidor #{number}",
      provider_account_reference: "merchant-#{number}",
      status: "active"
    }
  end

  def polo_merchant_account_factory do
    %PoloMerchantAccount{
      role: "primary",
      valid_during: tstz_range(@default_range_start),
      inserted_at: timestamp()
    }
  end

  def order_factory do
    number = sequence(:order, & &1)

    %Order{
      order_number: "DEMO-#{number}",
      idempotency_key: "demo-order-#{number}",
      currency: "BRL",
      subtotal_amount: Decimal.new("29.90"),
      discount_amount: Decimal.new("0.00"),
      total_amount: Decimal.new("29.90"),
      status: "paid",
      placed_at: @default_range_start
    }
  end

  def order_item_factory do
    %OrderItem{
      quantity: 1,
      unit_amount: Decimal.new("29.90"),
      total_amount: Decimal.new("29.90"),
      inserted_at: timestamp()
    }
  end

  def payment_intent_factory do
    number = sequence(:payment_intent, & &1)

    %PaymentIntent{
      idempotency_key: "payment-intent-#{number}",
      provider_reference: "intent-#{number}",
      currency: "BRL",
      amount: Decimal.new("29.90"),
      status: "succeeded"
    }
  end

  def payment_factory do
    number = sequence(:payment, & &1)
    now = timestamp()

    %Payment{
      provider_reference: "payment-#{number}",
      currency: "BRL",
      amount: Decimal.new("29.90"),
      status: "captured",
      captured_at: now,
      inserted_at: now
    }
  end

  def payment_provider_event_factory do
    number = sequence(:payment_provider_event, & &1)

    %PaymentProviderEvent{
      external_event_id: "event-#{number}",
      event_type: "payment.captured",
      payload: %{},
      payload_sha256: :crypto.hash(:sha256, "event-#{number}"),
      received_at: timestamp()
    }
  end

  def access_contract_factory do
    %AccessContract{
      status: "active",
      starts_at: @default_range_start,
      activated_at: @default_range_start
    }
  end

  def contract_event_factory do
    %ContractEvent{
      sequence: 1,
      event_type: "activated",
      payload: %{},
      occurred_at: timestamp(),
      inserted_at: timestamp()
    }
  end

  def benefit_cycle_factory do
    %BenefitCycle{
      sequence: 1,
      benefits_during: tstz_range(@default_range_start, @default_range_end),
      status: "active",
      activated_at: @default_range_start,
      inserted_at: timestamp()
    }
  end

  def cycle_entitlement_subject_factory do
    %CycleEntitlementSubject{subject_kind: "contract", inserted_at: timestamp()}
  end

  def entitlement_allocation_factory do
    %EntitlementAllocation{
      allocation_kind: "per_place",
      issued_units: 1,
      available_units: 1
    }
  end

  def validation_point_factory do
    number = sequence(:validation_point, & &1)

    %ValidationPoint{
      name: "Validação Demo #{number}",
      kind: "api",
      status: "active"
    }
  end

  def validation_credential_factory do
    number = sequence(:validation_credential, & &1)

    %ValidationCredential{
      version: 1,
      kind: "api_key",
      secret_hash: :crypto.hash(:sha256, "validation-credential-#{number}"),
      valid_during: tstz_range(@default_range_start),
      status: "active",
      inserted_at: timestamp()
    }
  end

  @spec unique_email() :: String.t()
  def unique_email do
    sequence(:email, &"member-#{&1}@example.test")
  end

  @spec unique_slug(String.t()) :: String.t()
  def unique_slug(prefix) when is_binary(prefix) and prefix != "" do
    sequence(:slug, &"#{prefix}-#{&1}")
  end

  @spec cpf() :: String.t()
  def cpf do
    sequence(:cpf, &Brazil.cpf/1)
  end

  @spec cnpj() :: String.t()
  def cnpj do
    sequence(:cnpj, &Brazil.cnpj/1)
  end

  @spec person_name() :: String.t()
  def person_name do
    PtBr.name()
  end

  @spec tstz_range(DateTime.t(), DateTime.t() | :unbound) :: Postgrex.Range.t()
  def tstz_range(lower, upper \\ :unbound) do
    %Postgrex.Range{
      lower: lower,
      upper: upper,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp timestamp, do: DateTime.utc_now(:microsecond)
end
