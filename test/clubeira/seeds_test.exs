defmodule Clubeira.SeedsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.User
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Catalog.Edition
  alias Clubeira.Catalog.EditionPlace
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.City
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Subscriptions

  test "demo seed is idempotent and isolated by polo under a non-bypass RLS role" do
    first_result = Seeds.run!()
    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", "clubeira-demo-local")
    assert {:ok, session} = Accounts.login("membro.demo@clubeira.local", password)

    assert Seeds.run!() == first_result
    assert {:ok, _scope} = Accounts.fetch_scope_by_api_token(session.token)

    assert Repo.aggregate(City, :count) == 2
    assert Repo.aggregate(Organization, :count) == 2
    assert Repo.aggregate(Brand, :count) == 2
    assert Repo.aggregate(Place, :count) == 3
    assert Repo.aggregate(PoloRoute, :count) == 2
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(PasswordCredential, :count) == 1

    assert_polo_counts(Ids.fetch!(:polo_sobral),
      polo_places: 2,
      edition_places: 2,
      benefit_offers: 2,
      offer_places: 2
    )

    assert_polo_counts(Ids.fetch!(:polo_londrina),
      polo_places: 1,
      edition_places: 1,
      benefit_offers: 1,
      offer_places: 1
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
  end
end
