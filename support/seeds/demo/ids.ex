defmodule Clubeira.Seeds.Demo.Ids do
  @moduledoc """
  Stable UUIDv7 identifiers for the canonical development scenario.

  These values are fixture identity. Never regenerate them during a seed run.
  """

  @ids %{
    city_sobral: "019fc8f0-cbfd-79bc-a122-f5e52e9e7266",
    city_londrina: "019fc8f0-cbfd-7b14-9ef1-672c8c0b43f4",
    organization_franchise: "019fc8f0-cbfd-7b97-a1a5-9231b86040d3",
    organization_local_sobral: "019fc8f0-cbfd-7c09-afae-e8ebcc2e7c5c",
    brand_franchise: "019fc8f0-cbfd-7c34-8d62-bec9c5683716",
    brand_local_sobral: "019fc8f0-cbfd-7c5b-884e-d0578a484d3d",
    address_franchise_sobral: "019fc8f0-cbfd-7c8a-bc0c-e4c557493d03",
    address_franchise_londrina: "019fc8f0-cbfd-7cb5-b7c2-94f58421260c",
    address_local_sobral: "019fc8f0-cbfd-7cf4-a7a4-aed1e47d0ebd",
    place_franchise_sobral: "019fc8f0-cbfd-7d1c-b182-e6a174a7beab",
    place_franchise_londrina: "019fc8f0-cbfd-7d7d-88db-37c974529389",
    place_local_sobral: "019fc8f0-cbfd-7e1b-9554-2c419936e2bb",
    brand_ownership_franchise: "019fc8f0-cbfd-7e6a-a116-0a1b5f14efe4",
    brand_ownership_local_sobral: "019fc8f0-cbfd-7e93-979f-c5400f1d36ae",
    place_brand_franchise_sobral: "019fc8f0-cbfd-7ec2-aaa3-a493719e35cc",
    place_brand_franchise_londrina: "019fc8f0-cbfd-7f2f-8aad-ee655132fc38",
    place_brand_local_sobral: "019fc8f0-cbfd-7f86-9bf5-570224e4c87e",
    place_operator_franchise_sobral: "019fc8f0-cbfd-7fcc-a45f-8e977c3d40a6",
    place_operator_franchise_londrina: "019fc8f0-cbfd-7ffb-ae20-da9add16d756",
    place_operator_local_sobral: "019fc8f0-cbfe-702b-8312-b5d50154fe89",
    polo_sobral: "019fc8f0-cbfe-7054-a01c-a9b0664c89ba",
    polo_londrina: "019fc8f0-cbfe-7073-9c5e-6fbe8a68a8b1",
    policy_sobral: "019fc8f0-cbfe-7094-9be1-06623b841959",
    policy_londrina: "019fc8f0-cbfe-70b4-a33c-d276c37bfe7a",
    polo_place_franchise_sobral: "019fc8f0-cbfe-7135-80d9-a0de78c352bf",
    polo_place_franchise_londrina: "019fc8f0-cbfe-71e0-9e3f-793e41154bb3",
    polo_place_local_sobral: "019fc8f0-cbfe-7284-b244-1689bf84bb71",
    edition_sobral: "019fc8f0-cbfe-72ed-8612-dd0549ec2117",
    edition_londrina: "019fc8f0-cbfe-731a-9fe1-45099e76da5e",
    benefit_offer_franchise_sobral: "019fc8f0-cbfe-73a1-8b9b-e74f23b2ac01",
    benefit_offer_version_franchise_sobral: "019fc8f0-cbfe-73c2-902d-a83e74a51b02",
    benefit_offer_local_sobral: "019fc8f0-cbfe-73e3-a627-9a456e32bc03",
    benefit_offer_version_local_sobral: "019fc8f0-cbfe-7404-b218-cc914b62ad04",
    benefit_offer_franchise_londrina: "019fc8f0-cbfe-7425-87f4-da385ca3be05",
    benefit_offer_version_franchise_londrina: "019fc8f0-cbfe-7446-9d73-eb427fa4cd06"
  }

  @spec fetch!(atom()) :: Ecto.UUID.t()
  def fetch!(name), do: Map.fetch!(@ids, name)

  @spec all() :: %{atom() => Ecto.UUID.t()}
  def all, do: @ids
end
