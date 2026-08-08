defmodule Clubeira.SeedsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Catalog
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Catalog.Edition
  alias Clubeira.Catalog.EditionPlace
  alias Clubeira.Devices
  alias Clubeira.Directory
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationIdentifier
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.OrganizationMembershipRole
  alias Clubeira.Directory.OrganizationRole
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PlaceStaffAssignment
  alias Clubeira.Directory.PlaceStaffAssignmentRole
  alias Clubeira.Directory.PlaceStaffRole
  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Directory.PoloPlaceProfileCategory
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory.Brazil
  alias Clubeira.Legal.Acceptance
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Redemptions
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Subscriptions
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Tenancy.ActorScope
  alias Clubeira.Tenancy.Scope

  @demo_validation_secret "M-bCcLGupP8XuBxzemHd-4JumJf6trsiQpinEl30xwg"

  test "migrator seed is idempotent and its tenant data stays isolated under the runtime role" do
    first_result = Clubeira.TestDatabaseRole.as_owner(&Seeds.run!/0)
    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", "clubeira-demo-local")
    assert {:ok, session} = Accounts.login("membro.demo@clubeira.local", password)

    assert Clubeira.TestDatabaseRole.as_owner(&Seeds.run!/0) == first_result
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)

    assert Repo.aggregate(City, :count) == 2
    assert Repo.aggregate(Organization, :count) == 2
    assert Repo.aggregate(OrganizationIdentifier, :count) == 2
    assert Repo.aggregate(Brand, :count) == 2
    assert Repo.aggregate(Place, :count) == 3
    assert Repo.aggregate(PlaceCategory, :count) == 4
    assert Repo.aggregate(PoloRoute, :count) == 2
    assert Repo.aggregate(User, :count) == 4
    assert Repo.aggregate(PasswordCredential, :count) == 4
    assert Repo.aggregate(OrganizationRole, :count) == 1
    assert Repo.aggregate(OrganizationMembership, :count) == 1
    assert Repo.aggregate(OrganizationMembershipRole, :count) == 1
    assert Repo.aggregate(PlaceStaffRole, :count) == 1
    assert Repo.aggregate(PlaceStaffAssignment, :count) == 1
    assert Repo.aggregate(PlaceStaffAssignmentRole, :count) == 1
    assert Repo.aggregate(PaymentProvider, :count) == 1
    assert Repo.aggregate(MerchantAccount, :count) == 1
    assert Repo.aggregate(Document, :count) == 1
    assert Repo.aggregate(DocumentVersion, :count) == 1

    assert first_result.legal_document_version_id ==
             Ids.fetch!(:legal_document_version_consumer_terms_pt_br)

    assert Repo.aggregate(Acceptance, :count) == 0

    actor_scope = ActorScope.new!(session.user.id, scope.request_id)

    assert {:ok, 1} =
             Repo.transact_as_actor(actor_scope, fn ->
               {:ok, Repo.aggregate(Acceptance, :count)}
             end)

    assert_polo_counts(Ids.fetch!(:polo_sobral),
      polo_places: 2,
      edition_places: 2,
      benefit_offers: 2,
      offer_places: 2,
      place_profiles: 2,
      profile_categories: 4,
      opening_periods: 23,
      validation_points: 1,
      vouchers: 2
    )

    assert_polo_counts(Ids.fetch!(:polo_londrina),
      polo_places: 1,
      edition_places: 1,
      benefit_offers: 1,
      offer_places: 1,
      place_profiles: 1,
      profile_categories: 2,
      opening_periods: 9,
      validation_points: 0,
      vouchers: 1
    )

    franchise_id = Ids.fetch!(:organization_franchise)
    local_sobral_id = Ids.fetch!(:organization_local_sobral)

    assert operator_count(Ids.fetch!(:polo_sobral), franchise_id) == 1
    assert operator_count(Ids.fetch!(:polo_londrina), franchise_id) == 1
    assert operator_count(Ids.fetch!(:polo_londrina), local_sobral_id) == 0
    assert_seeded_place_profiles!()

    review = assert_member_api_scenario(first_result)
    assert_moderator_scenario(first_result, review)
    assert_partner_scenario(first_result)
    assert_admin_scenario(first_result)
  end

  test "canonical identifiers are unique UUIDv7 values" do
    identifiers = Ids.all() |> Map.values()

    assert length(identifiers) == MapSet.size(MapSet.new(identifiers))

    assert Enum.all?(identifiers, fn identifier ->
             match?({:ok, _binary}, Ecto.UUID.dump(identifier)) and
               String.at(identifier, 14) == "7"
           end)
  end

  test "Ecto factories persist application-generated UUIDv7 identifiers" do
    city = insert(:city)

    assert String.at(city.id, 14) == "7"
    assert Repo.get!(City, city.id).id == city.id
  end

  defp assert_polo_counts(polo_id, expected) do
    Seeds.with_polo!(polo_id, fn ->
      assert Repo.aggregate(Polo, :count) == 1
      assert Repo.aggregate(Edition, :count) == 1
      assert Repo.aggregate(PoloPlace, :count) == expected[:polo_places]
      assert Repo.aggregate(EditionPlace, :count) == expected[:edition_places]
      assert Repo.aggregate(BenefitOffer, :count) == expected[:benefit_offers]
      assert Repo.aggregate(PoloMerchantAccount, :count) == 1
      assert Repo.aggregate(ValidationPoint, :count) == expected[:validation_points]
      assert Repo.aggregate(ValidationCredential, :count) == expected[:validation_points]
      assert Repo.aggregate(BenefitOfferVersionPlace, :count) == expected[:offer_places]
      assert Repo.aggregate(PoloPlaceProfile, :count) == expected[:place_profiles]

      assert Repo.aggregate(PoloPlaceProfileCategory, :count) ==
               expected[:profile_categories]

      assert Repo.aggregate(PoloPlaceOpeningPeriod, :count) == expected[:opening_periods]
      assert Repo.aggregate(Order, :count) == 1
      assert Repo.aggregate(OrderItem, :count) == 1
      assert Repo.aggregate(PaymentIntent, :count) == 1
      assert Repo.aggregate(Payment, :count) == 1
      assert Repo.aggregate(PaymentProviderEvent, :count) == 1
      assert Repo.aggregate(DomainEvent, :count) == 4
      assert Repo.aggregate(OutboxMessage, :count) == 4
      assert Repo.aggregate(TenantEvent, :count) == 3
      assert Repo.aggregate(AccessContract, :count) == 1
      assert Repo.aggregate(EntitlementAllocation, :count) == expected[:vouchers]
    end)
  end

  defp assert_seeded_place_profiles! do
    assert {:ok, sobral} = Directory.fetch_public("sobral")
    assert {:ok, londrina} = Directory.fetch_public("londrina")

    sobral_cafe = place_profile!(sobral, :place_franchise_sobral)
    sobral_restaurant = place_profile!(sobral, :place_local_sobral)
    londrina_cafe = place_profile!(londrina, :place_franchise_londrina)

    assert sobral_cafe["contact"] == %{
             "email" => "sobral@cafe-horizonte.example",
             "phone" => "+5588999991001"
           }

    assert Enum.map(sobral_cafe["categories"], & &1["key"]) == ["cafe", "bakery"]
    assert length(sobral_cafe["weekly_hours"]) == 7
    assert Enum.map(sobral_cafe["special_hours"], & &1["kind"]) == ["closed", "custom"]

    assert sobral_restaurant["contact"] == %{
             "email" => "reservas@sabores-do-acarau.example",
             "phone" => "+5588999991002"
           }

    assert Enum.map(sobral_restaurant["categories"], & &1["key"]) == [
             "restaurant",
             "regional-cuisine"
           ]

    assert length(sobral_restaurant["weekly_hours"]) == 12
    assert length(sobral_restaurant["special_hours"]) == 2

    assert londrina_cafe["contact"] == %{
             "email" => "londrina@cafe-horizonte.example",
             "phone" => "+5543999991003"
           }

    assert Enum.map(londrina_cafe["categories"], & &1["key"]) == ["cafe", "bakery"]
    assert length(londrina_cafe["weekly_hours"]) == 7
    assert length(londrina_cafe["special_hours"]) == 2
  end

  defp place_profile!(directory, place_id_name) do
    place_id = Ids.fetch!(place_id_name)
    place = Enum.find(directory.places, &(&1.place_id == place_id))
    refute is_nil(place)
    refute is_nil(place.profile)
    place.profile
  end

  defp operator_count(polo_id, organization_id) do
    Seeds.with_polo!(polo_id, fn ->
      %{rows: [[count]]} =
        Repo.query!(
          """
          SELECT count(*)
          FROM polo_places AS pp
          JOIN place_operators AS po ON po.place_id = pp.place_id
          WHERE po.organization_id = $1
          """,
          [Ecto.UUID.dump!(organization_id)]
        )

      count
    end)
  end

  defp assert_member_api_scenario(seed_result) do
    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", "clubeira-demo-local")

    assert {:ok, session} = Accounts.login("membro.demo@clubeira.local", password)
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)

    assert {:ok, %{options: [%{renewal_policy: "none"}]}} =
             Catalog.fetch_checkout_options("sobral")

    assert {:ok, subscriptions} = Subscriptions.list_for_account(scope)
    assert length(subscriptions) == 2

    assert {:ok, %{vouchers: sobral_vouchers}} = Subscriptions.list_wallet(scope, "sobral")
    assert {:ok, %{vouchers: londrina_vouchers}} = Subscriptions.list_wallet(scope, "londrina")
    assert length(sobral_vouchers) == 2
    assert length(londrina_vouchers) == 1

    installation_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, _enrollment} =
             Devices.enroll_redemption_device(scope, "sobral", %{
               access_contract_id: seed_result.member.polos.sobral.contract_id,
               installation_token: installation_token,
               platform: "web"
             })

    assert {:ok, grant} =
             Redemptions.issue_grant(scope, "sobral", %{
               entitlement_allocation_id: seed_result.member.polos.sobral.allocations.franchise,
               installation_token: installation_token
             })

    validation_secret =
      System.get_env("CLUBEIRA_DEMO_VALIDATION_SECRET", @demo_validation_secret)

    assert {:ok, redemption} =
             Redemptions.confirm_grant(
               "sobral",
               %{
                 grant: grant.token,
                 validation_credential: validation_secret,
                 idempotency_key: "demo-seed-redemption"
               },
               RequestContext.new!()
             )

    assert redemption.entitlement_allocation_id ==
             seed_result.member.polos.sobral.allocations.franchise

    review_scope =
      Scope.new!(Ids.fetch!(:polo_sobral),
        actor_user_id: session.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, submission} =
             Reviews.submit_verified(review_scope, %{
               place_id: Ids.fetch!(:place_franchise_sobral),
               source_redemption_id: redemption.id,
               rating: 5,
               title: "Café e atendimento excelentes",
               body: "O benefício demo foi entregue como anunciado.",
               idempotency_key: "demo-seed-review"
             })

    submission.review
  end

  defp assert_moderator_scenario(seed_result, pending_review) do
    password =
      System.get_env("CLUBEIRA_DEMO_MODERATOR_PASSWORD", "clubeira-moderador-local")

    assert seed_result.moderator_email == "moderador.demo@clubeira.local"
    assert {:ok, session} = Accounts.login(seed_result.moderator_email, password)

    scope =
      Scope.new!(Ids.fetch!(:polo_sobral),
        actor_user_id: session.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, %{reviews: [queued_review], page: %{has_more: false}}} =
             Reviews.list_for_moderation(scope, %{})

    assert queued_review.id == pending_review.id

    assert {:ok, moderation} =
             Reviews.moderate(scope, %{
               review_id: pending_review.id,
               action: "publish",
               reason: "Conteúdo verificado no cenário demo.",
               idempotency_key: "demo-seed-moderation"
             })

    assert moderation.review.status == "published"

    public_scope =
      Scope.new!(Ids.fetch!(:polo_sobral), request_id: Ecto.UUID.generate(version: 7))

    assert {:ok, %{reviews: [published_review]}} =
             Reviews.list_public(public_scope, Ids.fetch!(:place_franchise_sobral), %{})

    assert published_review.id == pending_review.id
  end

  defp assert_admin_scenario(seed_result) do
    password = System.get_env("CLUBEIRA_DEMO_ADMIN_PASSWORD", "clubeira-admin-local")

    assert seed_result.admin_email == "admin.demo@clubeira.local"
    assert {:ok, session} = Accounts.login(seed_result.admin_email, password)

    scope =
      Scope.new!(Ids.fetch!(:polo_sobral),
        actor_user_id: session.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, onboarding} =
             Directory.onboard_partner(scope, %{
               organization: %{
                 legal_name: "Bistrô Demo da Serra Ltda.",
                 trade_name: "Bistrô Demo da Serra",
                 cnpj: Brazil.cnpj(42_424)
               },
               place: %{
                 name: "Bistrô Demo da Serra Centro",
                 slug: "bistro-demo-da-serra-centro",
                 address: %{
                   postal_code: "62010000",
                   street: "Rua Demo do Administrador",
                   number: "42",
                   district: "Centro"
                 }
               },
               idempotency_key: "demo-admin-partner-onboarding"
             })

    assert {:ok, directory} = Directory.fetch_public("sobral")

    assert Enum.any?(directory.places, fn place ->
             place.place_id == onboarding.place.id and
               place.polo_place_id == onboarding.participation.id
           end)
  end

  defp assert_partner_scenario(seed_result) do
    password =
      System.get_env("CLUBEIRA_DEMO_PARTNER_PASSWORD", "clubeira-parceiro-local")

    assert seed_result.partner_email == "parceiro.demo@clubeira.local"
    assert {:ok, session} = Accounts.login(seed_result.partner_email, password)

    sobral_scope =
      Scope.new!(Ids.fetch!(:polo_sobral),
        actor_user_id: session.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, %{places: [place], page: %{has_more: false}}} =
             Directory.list_partner_places(sobral_scope, %{})

    assert place.place.id == Ids.fetch!(:place_local_sobral)

    londrina_scope =
      Scope.new!(Ids.fetch!(:polo_londrina),
        actor_user_id: session.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:error, :partner_access_required} =
             Directory.list_partner_places(londrina_scope, %{})
  end
end
