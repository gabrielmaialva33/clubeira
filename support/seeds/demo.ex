defmodule Clubeira.Seeds.Demo do
  @moduledoc """
  Canonical, fictional development scenario for the first multi-polo slice.

  It proves that a global franchise can operate places in independent polos
  while a local partner remains scoped to a single city and polo.
  """

  alias Clubeira.Seeds.Demo.Billing
  alias Clubeira.Seeds.Demo.Directory
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Demo.Legal
  alias Clubeira.Seeds.Demo.Member
  alias Clubeira.Seeds.Demo.Moderator
  alias Clubeira.Seeds.Demo.Polo

  @spec run!() :: map()
  def run! do
    legal = Legal.run!()
    directory = Directory.run!()

    Polo.run!(
      id: id(:polo_sobral),
      policy_id: id(:policy_sobral),
      edition_id: id(:edition_sobral),
      city: directory.cities.sobral,
      slug: "sobral",
      name: "Clubeira Sobral",
      timezone: "America/Fortaleza",
      places: [
        {directory.places.franchise_sobral, id(:polo_place_franchise_sobral)},
        {directory.places.local_sobral, id(:polo_place_local_sobral)}
      ],
      validation_points: [
        %{
          id: id(:validation_point_sobral),
          credential_id: id(:validation_credential_sobral),
          polo_place_id: id(:polo_place_franchise_sobral),
          name: "Caixa Demo Café Horizonte"
        }
      ],
      offers: [
        %{
          id: id(:benefit_offer_franchise_sobral),
          version_id: id(:benefit_offer_version_franchise_sobral),
          polo_place_id: id(:polo_place_franchise_sobral),
          code: "cafe-cortesia",
          name: "Café cortesia",
          benefit_kind: "complimentary_item",
          title: "Ganhe um café da casa",
          description: "Um café da casa por ciclo no Café Horizonte Demo de Sobral."
        },
        %{
          id: id(:benefit_offer_local_sobral),
          version_id: id(:benefit_offer_version_local_sobral),
          polo_place_id: id(:polo_place_local_sobral),
          code: "sobremesa-cortesia",
          name: "Sobremesa cortesia",
          benefit_kind: "complimentary_item",
          title: "Ganhe uma sobremesa regional",
          description: "Uma sobremesa selecionada por ciclo no Sabores do Acaraú Demo."
        }
      ]
    )

    Polo.run!(
      id: id(:polo_londrina),
      policy_id: id(:policy_londrina),
      edition_id: id(:edition_londrina),
      city: directory.cities.londrina,
      slug: "londrina",
      name: "Clubeira Londrina",
      timezone: "America/Sao_Paulo",
      places: [
        {directory.places.franchise_londrina, id(:polo_place_franchise_londrina)}
      ],
      offers: [
        %{
          id: id(:benefit_offer_franchise_londrina),
          version_id: id(:benefit_offer_version_franchise_londrina),
          polo_place_id: id(:polo_place_franchise_londrina),
          code: "cafe-cortesia",
          name: "Café cortesia",
          benefit_kind: "complimentary_item",
          title: "Ganhe um café da casa",
          description: "Um café da casa por ciclo no Café Horizonte Demo de Londrina."
        }
      ]
    )

    billing = Billing.run!()
    member = Member.run!(billing)
    moderator = Moderator.run!()

    %{
      profile: :demo,
      cities: 2,
      organizations: 2,
      brands: 2,
      places: 3,
      polos: 2,
      editions: 2,
      benefit_offers: 3,
      merchant_account_id: billing.account.id,
      merchant_account_reference: billing.account.provider_account_reference,
      legal_document_version_id: legal.version.id,
      validation_point_id: id(:validation_point_sobral),
      member_email: member.email,
      member: member,
      moderator_email: moderator.email,
      payment_provider: billing.provider.code,
      subscriptions: member.subscriptions,
      vouchers: member.vouchers
    }
  end

  defp id(name), do: Ids.fetch!(name)
end
