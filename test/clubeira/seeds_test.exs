defmodule Clubeira.SeedsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.User
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Catalog.Edition
  alias Clubeira.Catalog.EditionPlace
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Devices
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Legal.Acceptance
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Redemptions
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.ActorScope

  @demo_validation_secret "M-bCcLGupP8XuBxzemHd-4JumJf6trsiQpinEl30xwg"

  test "migrator seed is idempotent and its tenant data stays isolated under the runtime role" do
    first_result = Clubeira.TestDatabaseRole.as_owner(&Seeds.run!/0)
    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", "clubeira-demo-local")
    assert {:ok, session} = Accounts.login("membro.demo@clubeira.local", password)

    assert Clubeira.TestDatabaseRole.as_owner(&Seeds.run!/0) == first_result
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)

    assert Repo.aggregate(City, :count) == 2
    assert Repo.aggregate(Organization, :count) == 2
    assert Repo.aggregate(Brand, :count) == 2
    assert Repo.aggregate(Place, :count) == 3
    assert Repo.aggregate(PoloRoute, :count) == 2
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(PasswordCredential, :count) == 1
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
      validation_points: 1
    )

    assert_polo_counts(Ids.fetch!(:polo_londrina),
      polo_places: 1,
      edition_places: 1,
      benefit_offers: 1,
      offer_places: 1,
      validation_points: 0
    )

    franchise_id = Ids.fetch!(:organization_franchise)
    local_sobral_id = Ids.fetch!(:organization_local_sobral)

    assert operator_count(Ids.fetch!(:polo_sobral), franchise_id) == 1
    assert operator_count(Ids.fetch!(:polo_londrina), franchise_id) == 1
    assert operator_count(Ids.fetch!(:polo_londrina), local_sobral_id) == 0

    assert_member_api_scenario()
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
    end)
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

  defp assert_member_api_scenario do
    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", "clubeira-demo-local")

    assert {:ok, session} = Accounts.login("membro.demo@clubeira.local", password)
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert {:ok, subscriptions} = Subscriptions.list_for_account(scope)
    assert length(subscriptions) == 2

    assert {:ok, %{vouchers: sobral_vouchers}} = Subscriptions.list_wallet(scope, "sobral")
    assert {:ok, %{vouchers: londrina_vouchers}} = Subscriptions.list_wallet(scope, "londrina")
    assert length(sobral_vouchers) == 2
    assert length(londrina_vouchers) == 1

    installation_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, _enrollment} =
             Devices.enroll_redemption_device(scope, "sobral", %{
               access_contract_id: Ids.fetch!(:access_contract_sobral),
               installation_token: installation_token,
               platform: "web"
             })

    assert {:ok, grant} =
             Redemptions.issue_grant(scope, "sobral", %{
               entitlement_allocation_id: Ids.fetch!(:allocation_franchise_sobral),
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

    assert redemption.entitlement_allocation_id == Ids.fetch!(:allocation_franchise_sobral)
  end
end
