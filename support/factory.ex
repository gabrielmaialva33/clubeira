defmodule Clubeira.Factory do
  @moduledoc """
  Shared factory entrypoint for development data and tests.

  Canonical seeds pass explicit deterministic values to these factories.
  Reserve Faker for presentation data that is irrelevant to behavior, and pass
  required associations explicitly when a table has composite scope rules.
  """

  use ExMachina.Ecto, repo: Clubeira.Repo

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
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceBrand
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Factory.Brazil
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Polos.PoloRoute
  alias Faker.Person.PtBr

  @default_range_start ~U[2026-01-01 00:00:00Z]
  @default_range_end ~U[2027-01-01 00:00:00Z]

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
