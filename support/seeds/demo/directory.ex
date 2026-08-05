defmodule Clubeira.Seeds.Demo.Directory do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Factory.Brazil
  alias Clubeira.Security.IdentifierVault
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @range_start ~U[2026-01-01 00:00:00Z]

  @city_fields ~w(country_code subdivision_code external_code name timezone status updated_at)a
  @organization_fields ~w(kind legal_name trade_name country_code status updated_at)a
  @brand_fields ~w(slug name status updated_at)a
  @address_fields ~w(city_id postal_code street number complement district latitude longitude updated_at)a
  @place_fields ~w(city_id address_id slug name timezone status updated_at)a

  @spec run!() :: map()
  def run! do
    cities = seed_cities!()
    organizations = seed_organizations!()
    seed_organization_identifiers!(organizations)
    brands = seed_brands!()
    addresses = seed_addresses!(cities)
    places = seed_places!(cities, addresses)

    seed_relationships!(organizations, brands, places)

    %{cities: cities, places: places}
  end

  defp seed_cities! do
    sobral =
      Writer.upsert!(
        :city,
        %{
          id: id(:city_sobral),
          country_code: "BR",
          subdivision_code: "BR-CE",
          external_code: "2312908",
          name: "Sobral",
          timezone: "America/Fortaleza",
          status: "active"
        },
        @city_fields
      )

    londrina =
      Writer.upsert!(
        :city,
        %{
          id: id(:city_londrina),
          country_code: "BR",
          subdivision_code: "BR-PR",
          external_code: "4113700",
          name: "Londrina",
          timezone: "America/Sao_Paulo",
          status: "active"
        },
        @city_fields
      )

    %{sobral: sobral, londrina: londrina}
  end

  defp seed_organizations! do
    franchise =
      Writer.upsert!(
        :organization,
        %{
          id: id(:organization_franchise),
          kind: "legal_entity",
          legal_name: "Café Horizonte Franquias Demo Ltda.",
          trade_name: "Café Horizonte Demo",
          country_code: "BR",
          status: "active"
        },
        @organization_fields
      )

    local_sobral =
      Writer.upsert!(
        :organization,
        %{
          id: id(:organization_local_sobral),
          kind: "legal_entity",
          legal_name: "Sabores do Acaraú Demo Ltda.",
          trade_name: "Sabores do Acaraú Demo",
          country_code: "BR",
          status: "active"
        },
        @organization_fields
      )

    %{franchise: franchise, local_sobral: local_sobral}
  end

  defp seed_brands! do
    franchise =
      Writer.upsert!(
        :brand,
        %{
          id: id(:brand_franchise),
          slug: "cafe-horizonte-demo",
          name: "Café Horizonte Demo",
          status: "active"
        },
        @brand_fields
      )

    local_sobral =
      Writer.upsert!(
        :brand,
        %{
          id: id(:brand_local_sobral),
          slug: "sabores-do-acarau-demo",
          name: "Sabores do Acaraú Demo",
          status: "active"
        },
        @brand_fields
      )

    %{franchise: franchise, local_sobral: local_sobral}
  end

  defp seed_organization_identifiers!(organizations) do
    seed_cnpj!(
      organizations.franchise,
      id(:organization_identifier_franchise_cnpj),
      Brazil.cnpj(1_001)
    )

    seed_cnpj!(
      organizations.local_sobral,
      id(:organization_identifier_local_sobral_cnpj),
      Brazil.cnpj(1_002)
    )
  end

  defp seed_cnpj!(organization, identifier_id, cnpj) do
    sealed = IdentifierVault.seal("cnpj", cnpj)

    Writer.insert_once!(:organization_identifier, %{
      id: identifier_id,
      organization: organization,
      kind: "cnpj",
      ciphertext: sealed.ciphertext,
      lookup_token: sealed.lookup_token,
      key_version: sealed.key_version,
      verified_at: @range_start,
      inserted_at: @range_start
    })
  end

  defp seed_addresses!(cities) do
    franchise_sobral =
      Writer.upsert!(
        :address,
        %{
          id: id(:address_franchise_sobral),
          city: cities.sobral,
          street: "Rua Demo da Franquia",
          number: "100",
          district: "Centro"
        },
        @address_fields
      )

    franchise_londrina =
      Writer.upsert!(
        :address,
        %{
          id: id(:address_franchise_londrina),
          city: cities.londrina,
          street: "Rua Demo da Franquia",
          number: "200",
          district: "Centro"
        },
        @address_fields
      )

    local_sobral =
      Writer.upsert!(
        :address,
        %{
          id: id(:address_local_sobral),
          city: cities.sobral,
          street: "Rua Demo do Parceiro Local",
          number: "300",
          district: "Centro"
        },
        @address_fields
      )

    %{
      franchise_sobral: franchise_sobral,
      franchise_londrina: franchise_londrina,
      local_sobral: local_sobral
    }
  end

  defp seed_places!(cities, addresses) do
    franchise_sobral =
      Writer.upsert!(
        :place,
        %{
          id: id(:place_franchise_sobral),
          city: cities.sobral,
          address: addresses.franchise_sobral,
          slug: "cafe-horizonte-demo-sobral",
          name: "Café Horizonte Demo — Sobral",
          timezone: "America/Fortaleza",
          status: "active"
        },
        @place_fields
      )

    franchise_londrina =
      Writer.upsert!(
        :place,
        %{
          id: id(:place_franchise_londrina),
          city: cities.londrina,
          address: addresses.franchise_londrina,
          slug: "cafe-horizonte-demo-londrina",
          name: "Café Horizonte Demo — Londrina",
          timezone: "America/Sao_Paulo",
          status: "active"
        },
        @place_fields
      )

    local_sobral =
      Writer.upsert!(
        :place,
        %{
          id: id(:place_local_sobral),
          city: cities.sobral,
          address: addresses.local_sobral,
          slug: "sabores-do-acarau-demo-sobral",
          name: "Sabores do Acaraú Demo — Sobral",
          timezone: "America/Fortaleza",
          status: "active"
        },
        @place_fields
      )

    %{
      franchise_sobral: franchise_sobral,
      franchise_londrina: franchise_londrina,
      local_sobral: local_sobral
    }
  end

  defp seed_relationships!(organizations, brands, places) do
    Writer.insert_once!(:brand_ownership, %{
      id: id(:brand_ownership_franchise),
      brand: brands.franchise,
      organization: organizations.franchise,
      valid_during: active_range()
    })

    Writer.insert_once!(:brand_ownership, %{
      id: id(:brand_ownership_local_sobral),
      brand: brands.local_sobral,
      organization: organizations.local_sobral,
      valid_during: active_range()
    })

    seed_place_relationships!(
      places.franchise_sobral,
      brands.franchise,
      organizations.franchise,
      place_brand_id: id(:place_brand_franchise_sobral),
      place_operator_id: id(:place_operator_franchise_sobral)
    )

    seed_place_relationships!(
      places.franchise_londrina,
      brands.franchise,
      organizations.franchise,
      place_brand_id: id(:place_brand_franchise_londrina),
      place_operator_id: id(:place_operator_franchise_londrina)
    )

    seed_place_relationships!(
      places.local_sobral,
      brands.local_sobral,
      organizations.local_sobral,
      place_brand_id: id(:place_brand_local_sobral),
      place_operator_id: id(:place_operator_local_sobral)
    )
  end

  defp seed_place_relationships!(place, brand, organization, ids) do
    Writer.insert_once!(:place_brand, %{
      id: Keyword.fetch!(ids, :place_brand_id),
      place: place,
      brand: brand,
      role: "primary",
      valid_during: active_range()
    })

    Writer.insert_once!(:place_operator, %{
      id: Keyword.fetch!(ids, :place_operator_id),
      place: place,
      organization: organization,
      role: "operator",
      valid_during: active_range()
    })
  end

  defp active_range, do: Factory.tstz_range(@range_start)
  defp id(name), do: Ids.fetch!(name)
end
