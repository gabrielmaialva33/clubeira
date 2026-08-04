defmodule Clubeira.Seeds.Demo.Member do
  @moduledoc false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Factory
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @member_email "membro.demo@clubeira.local"
  @default_password "clubeira-demo-local"
  @range_start ~U[2026-01-01 00:00:00Z]
  @range_end ~U[2027-01-01 00:00:00Z]

  @user_fields ~w(email status disabled_at updated_at)a
  @access_product_fields ~w(polo_id code name status updated_at)a

  @product_offering_fields ~w(
    polo_id access_product_version_id edition_id code scope_kind sales_channel status updated_at
  )a

  @spec run!() :: map()
  def run! do
    user = seed_user!()

    seed_subscription!(user,
      key: :sobral,
      polo_id: id(:polo_sobral),
      policy_id: id(:policy_sobral),
      scope_places: [
        id(:polo_place_franchise_sobral),
        id(:polo_place_local_sobral)
      ],
      items: [
        %{
          id: id(:package_item_franchise_sobral),
          offer_version_id: id(:benefit_offer_version_franchise_sobral),
          allocation_id: id(:allocation_franchise_sobral),
          allocation_kind: "per_place",
          polo_place_id: id(:polo_place_franchise_sobral)
        },
        %{
          id: id(:package_item_local_sobral),
          offer_version_id: id(:benefit_offer_version_local_sobral),
          allocation_id: id(:allocation_local_sobral),
          allocation_kind: "shared_scope",
          polo_place_id: nil
        }
      ]
    )

    seed_subscription!(user,
      key: :londrina,
      polo_id: id(:polo_londrina),
      policy_id: id(:policy_londrina),
      scope_places: [id(:polo_place_franchise_londrina)],
      items: [
        %{
          id: id(:package_item_franchise_londrina),
          offer_version_id: id(:benefit_offer_version_franchise_londrina),
          allocation_id: id(:allocation_franchise_londrina),
          allocation_kind: "per_place",
          polo_place_id: id(:polo_place_franchise_londrina)
        }
      ]
    )

    %{email: user.email, subscriptions: 2, vouchers: 3}
  end

  defp seed_user! do
    user =
      Writer.upsert!(
        :user,
        %{id: id(:member_user), email: @member_email, status: "active"},
        @user_fields
      )

    if is_nil(Repo.get(PasswordCredential, user.id)) do
      password = System.get_env("CLUBEIRA_DEMO_PASSWORD", @default_password)

      case Accounts.set_password(user, password) do
        {:ok, _credential} ->
          :ok

        {:error, changeset} ->
          raise "invalid CLUBEIRA_DEMO_PASSWORD: #{inspect(changeset.errors)}"
      end
    end

    user
  end

  defp seed_subscription!(user, options) do
    polo_id = Keyword.fetch!(options, :polo_id)

    Seeds.with_polo!(polo_id, fn ->
      polo = Repo.get!(Polo, polo_id)
      policy = Repo.get!(PoloPolicyVersion, Keyword.fetch!(options, :policy_id))
      commercial = seed_commercial_definition!(polo, options)
      entitlement = seed_entitlement_definition!(polo, commercial.offering_version, options)
      contract = seed_contract!(polo, policy, user, commercial, entitlement, options)

      seed_allocations!(polo, contract, entitlement, Keyword.fetch!(options, :items))
    end)
  end

  defp seed_commercial_definition!(polo, options) do
    key = Keyword.fetch!(options, :key)

    product =
      Writer.upsert!(
        :access_product,
        %{
          id: id(keyed(:access_product, key)),
          polo: polo,
          code: "clube-#{key}",
          name: "Clubeira #{humanize(key)}",
          status: "active"
        },
        @access_product_fields
      )

    product_version =
      Writer.insert_once!(:access_product_version, %{
        id: id(keyed(:access_product_version, key)),
        polo: polo,
        access_product: product,
        name: "Clubeira #{humanize(key)} mensal",
        description: "Um uso de cada voucher a cada ciclo mensal."
      })

    offering =
      Writer.upsert!(
        :product_offering,
        %{
          id: id(keyed(:product_offering, key)),
          polo: polo,
          access_product_version: product_version,
          code: "mensal-#{key}",
          scope_kind: "evergreen",
          sales_channel: "direct",
          status: "active"
        },
        @product_offering_fields
      )

    offering_version =
      Writer.insert_once!(:product_offering_version, %{
        id: id(keyed(:product_offering_version, key)),
        polo: polo,
        product_offering: offering,
        name: "Assinatura mensal #{humanize(key)}",
        description: "Benefícios independentes do outro polo."
      })

    price =
      Writer.insert_once!(:offering_price, %{
        id: id(keyed(:offering_price, key)),
        polo: polo,
        product_offering_version: offering_version
      })

    %{offering_version: offering_version, price: price}
  end

  defp seed_entitlement_definition!(polo, offering_version, options) do
    key = Keyword.fetch!(options, :key)

    package =
      Writer.insert_once!(:benefit_package, %{
        id: id(keyed(:benefit_package, key)),
        polo: polo,
        code: "beneficios-#{key}",
        name: "Benefícios #{humanize(key)}"
      })

    package_version =
      Writer.insert_once!(:benefit_package_version, %{
        id: id(keyed(:benefit_package_version, key)),
        polo: polo,
        benefit_package: package,
        name: "Benefícios #{humanize(key)} 2026"
      })

    scope =
      Writer.insert_once!(:entitlement_scope, %{
        id: id(keyed(:entitlement_scope, key)),
        polo: polo,
        benefit_package_version: package_version,
        key: "parceiros-#{key}",
        name: "Parceiros #{humanize(key)}"
      })

    seed_scope_places!(polo, scope, Keyword.fetch!(options, :scope_places))

    items =
      Enum.map(Keyword.fetch!(options, :items), fn item ->
        offer_version = Repo.get!(BenefitOfferVersion, item.offer_version_id)

        Writer.insert_once!(:benefit_package_item, %{
          id: item.id,
          polo: polo,
          benefit_package_version_id: package_version.id,
          benefit_offer_version: offer_version,
          entitlement_scope_id: scope.id,
          consumption_unit: item.allocation_kind
        })
      end)

    assignment =
      Writer.insert_once!(:product_offering_package_assignment, %{
        id: id(keyed(:package_assignment, key)),
        polo: polo,
        product_offering_version: offering_version,
        benefit_package_version: package_version
      })

    %{
      package_version: package_version,
      scope: scope,
      items: Map.new(items, &{&1.id, &1}),
      assignment: assignment
    }
  end

  defp seed_scope_places!(polo, scope, polo_place_ids) do
    Enum.each(polo_place_ids, fn polo_place_id ->
      Writer.insert_once!(:entitlement_scope_place, %{
        polo: polo,
        entitlement_scope_id: scope.id,
        polo_place: Repo.get!(PoloPlace, polo_place_id)
      })
    end)
  end

  defp seed_contract!(polo, policy, user, commercial, entitlement, options) do
    key = Keyword.fetch!(options, :key)

    order =
      Writer.insert_once!(:order, %{
        id: id(keyed(:order, key)),
        polo: polo,
        purchaser_user: user,
        order_number: "DEMO-#{String.upcase(to_string(key))}",
        idempotency_key: "demo-subscription-#{key}"
      })

    order_item =
      Writer.insert_once!(:order_item, %{
        id: id(keyed(:order_item, key)),
        polo: polo,
        order: order,
        product_offering_version: commercial.offering_version,
        offering_price: commercial.price
      })

    contract =
      Writer.insert_once!(:access_contract, %{
        id: id(keyed(:access_contract, key)),
        polo: polo,
        purchaser_user: user,
        order_item: order_item,
        product_offering_version: commercial.offering_version,
        polo_policy_version: policy
      })

    cycle =
      Writer.insert_once!(:benefit_cycle, %{
        id: id(keyed(:benefit_cycle, key)),
        polo: polo,
        access_contract: contract,
        benefit_package_version: entitlement.package_version,
        offering_package_assignment: entitlement.assignment,
        polo_policy_version: policy,
        benefits_during: Factory.tstz_range(@range_start, @range_end)
      })

    subject =
      Writer.insert_once!(:cycle_entitlement_subject, %{
        id: id(keyed(:entitlement_subject, key)),
        polo: polo,
        access_contract: contract,
        benefit_cycle: cycle
      })

    %{contract: contract, cycle: cycle, subject: subject}
  end

  defp seed_allocations!(polo, contract, entitlement, items) do
    Enum.each(items, fn item ->
      polo_place =
        if item.polo_place_id, do: Repo.get!(PoloPlace, item.polo_place_id)

      Writer.insert_once!(:entitlement_allocation, %{
        id: item.allocation_id,
        polo: polo,
        cycle_entitlement_subject: contract.subject,
        benefit_package_item_id: Map.fetch!(entitlement.items, item.id).id,
        entitlement_scope_id: entitlement.scope.id,
        polo_place: polo_place,
        allocation_kind: item.allocation_kind
      })
    end)
  end

  defp keyed(prefix, key), do: String.to_existing_atom("#{prefix}_#{key}")
  defp humanize(key), do: key |> to_string() |> String.capitalize()
  defp id(name), do: Ids.fetch!(name)
end
