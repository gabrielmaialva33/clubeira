defmodule Clubeira.Partnerships.AgreementOptionsReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.BillingFixtures
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.Partnerships
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "lists only references that can be published in the selected polo" do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede local")
    other_graph = agreement_graph!(other_fixture, "Rede de outro polo")

    assert {:ok, options} = Partnerships.list_agreement_options(admin_scope)

    assert Enum.map(options.organizations, & &1.id) == [graph.organization.id]
    refute Enum.any?(options.organizations, &(&1.id == other_graph.organization.id))

    assert [%{id: brand_id, organization_ids: organization_ids}] = options.brands
    assert brand_id == graph.brand.id
    assert organization_ids == [graph.organization.id]

    assert [%{id: polo_place_id, organization_ids: place_organization_ids}] = options.places
    assert polo_place_id == fixture.polo_place.id
    assert place_organization_ids == [graph.organization.id]

    assert Enum.any?(options.editions, &(&1.id == graph.edition.id))
    refute Enum.any?(options.editions, &(&1.id == other_graph.edition.id))

    benefit_offer_version_id = graph.benefit_offer_version_id

    assert Enum.any?(
             options.benefit_offer_versions,
             &(&1.id == benefit_offer_version_id)
           )

    refute Enum.any?(
             options.benefit_offer_versions,
             &(&1.id == other_graph.benefit_offer_version_id)
           )
  end

  test "requires a current manage_partners authorization" do
    fixture = BillingFixtures.create!()

    assert {:error, :partner_admin_required} =
             Partnerships.list_agreement_options(fixture.member_scope)

    assert {:error, :partner_admin_required} = Partnerships.list_agreement_options(nil)
  end

  defp agreement_graph!(fixture, organization_name) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        legal_name: "#{organization_name} Ltda.",
        trade_name: organization_name
      )

    brand = Factory.insert(:brand)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.polo_place.place_id),
      organization: organization
    )

    Factory.insert(:brand_ownership,
      brand: brand,
      organization: organization,
      valid_during: Factory.tstz_range(DateTime.add(now, -3_600))
    )

    assert {:ok, edition} =
             Repo.transact_in_polo(fixture.service_scope, fn ->
               {:ok, Factory.insert(:edition, polo: fixture.polo)}
             end)

    benefit_offer_version_id =
      fixture.package_items
      |> hd()
      |> Map.fetch!(:benefit_offer_version_id)

    %{
      organization: organization,
      brand: brand,
      edition: edition,
      benefit_offer_version_id: benefit_offer_version_id
    }
  end

  defp polo_fixture(fixture) do
    %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope}
  end
end
