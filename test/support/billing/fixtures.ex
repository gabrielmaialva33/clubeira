defmodule Clubeira.BillingFixtures do
  @moduledoc false

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec create!() :: map()
  def create! do
    polo_id = uuid7()
    user_id = uuid7()
    request_id = uuid7()

    member_scope = Scope.new!(polo_id, actor_user_id: user_id, request_id: request_id)
    service_scope = Scope.new!(polo_id, request_id: uuid7())

    {:ok, fixture} =
      Repo.transact_in_polo(member_scope, fn _repo ->
        city = Factory.insert(:city)
        user = Factory.insert(:user, id: user_id)
        polo = Factory.insert(:polo, id: polo_id, city: city)
        polo_route = Factory.insert(:polo_route, polo: polo)
        policy = Factory.insert(:polo_policy_version, polo: polo)

        address = Factory.insert(:address, city: city)
        place = Factory.insert(:place, city: city, address: address)
        polo_place = Factory.insert(:polo_place, city: city, polo: polo, place: place)

        commercial = insert_commercial!(polo)
        benefits = insert_benefits!(polo, polo_place, commercial.offering_version)
        provider = Factory.insert(:payment_provider)
        merchant_account = Factory.insert(:merchant_account, payment_provider: provider)

        {:ok,
         %{
           member_scope: member_scope,
           service_scope: service_scope,
           user: user,
           polo: polo,
           polo_route: polo_route,
           policy: policy,
           polo_place: polo_place,
           offering_version: commercial.offering_version,
           price: commercial.price,
           package_version: benefits.package_version,
           package_items: benefits.items,
           assignment: benefits.assignment,
           provider: provider,
           merchant_account: merchant_account,
           captured_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second),
           external_event_id: "evt-#{uuid7()}",
           provider_reference: "pay-#{uuid7()}"
         }}
      end)

    Map.put(fixture, :account_scope, account_scope(fixture.user, request_id))
  end

  @spec checkout_request(map(), map() | keyword()) :: map()
  def checkout_request(fixture, overrides \\ %{}) do
    Map.merge(
      %{
        product_offering_version_id: fixture.offering_version.id,
        offering_price_id: fixture.price.id,
        idempotency_key: "checkout-#{uuid7()}"
      },
      Map.new(overrides)
    )
  end

  @spec settled_payment(map(), struct(), map() | keyword()) :: map()
  def settled_payment(fixture, order, overrides \\ %{}) do
    Map.merge(
      %{
        order_id: order.id,
        payment_provider_id: fixture.provider.id,
        merchant_account_id: fixture.merchant_account.id,
        external_event_id: fixture.external_event_id,
        provider_reference: fixture.provider_reference,
        amount: order.total_amount,
        currency: order.currency,
        occurred_at: fixture.captured_at,
        payload: %{"source" => "billing_fixture"}
      },
      Map.new(overrides)
    )
  end

  defp insert_commercial!(polo) do
    product = Factory.insert(:access_product, polo: polo)
    product_version = Factory.insert(:access_product_version, polo: polo, access_product: product)

    offering =
      Factory.insert(:product_offering,
        polo: polo,
        access_product_version: product_version
      )

    offering_version =
      Factory.insert(:product_offering_version,
        polo: polo,
        product_offering: offering
      )

    price =
      Factory.insert(:offering_price,
        polo: polo,
        product_offering_version: offering_version
      )

    %{offering_version: offering_version, price: price}
  end

  defp account_scope(user, request_id) do
    %AccountScope{
      user: user,
      session_id: uuid7(),
      session_expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3_600),
      request_id: request_id
    }
  end

  defp insert_benefits!(polo, polo_place, offering_version) do
    package = Factory.insert(:benefit_package, polo: polo)

    package_version =
      Factory.insert(:benefit_package_version, polo: polo, benefit_package: package)

    scope =
      Factory.insert(:entitlement_scope,
        polo: polo,
        benefit_package_version: package_version
      )

    Factory.insert(:entitlement_scope_place,
      polo: polo,
      entitlement_scope_id: scope.id,
      polo_place: polo_place
    )

    per_place_item =
      insert_package_item!(polo, polo_place, package_version, scope,
        consumption_unit: "per_place"
      )

    shared_item =
      insert_package_item!(polo, polo_place, package_version, scope,
        consumption_unit: "shared_scope",
        priority: 200
      )

    assignment =
      Factory.insert(:product_offering_package_assignment,
        polo: polo,
        product_offering_version: offering_version,
        benefit_package_version: package_version
      )

    %{
      package_version: package_version,
      items: [per_place_item, shared_item],
      assignment: assignment
    }
  end

  defp insert_package_item!(polo, polo_place, package_version, scope, attributes) do
    offer = Factory.insert(:benefit_offer, polo: polo)

    offer_version =
      Factory.insert(:benefit_offer_version, polo: polo, benefit_offer: offer)

    Factory.insert(:benefit_offer_version_place,
      polo: polo,
      benefit_offer_version: offer_version,
      polo_place: polo_place
    )

    Factory.insert(
      :benefit_package_item,
      Keyword.merge(
        [
          polo: polo,
          benefit_package_version_id: package_version.id,
          benefit_offer_version: offer_version,
          entitlement_scope_id: scope.id
        ],
        attributes
      )
    )
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
