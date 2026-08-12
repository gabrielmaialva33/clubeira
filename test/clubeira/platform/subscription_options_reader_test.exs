defmodule Clubeira.Platform.SubscriptionOptionsReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.BillingFixtures
  alias Clubeira.Factory
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.Price
  alias Clubeira.PlatformBilling
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "lists only currently purchasable platform prices for a polo billing admin" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    {current, future, inactive} = subscription_options_fixture!()

    assert {:ok, [option]} = PlatformBilling.list_subscription_options(admin_scope)

    assert option.price.id == current.price.id
    assert option.plan.code == current.plan.code
    assert option.version.id == current.version.id
    refute option.price.id == future.price.id
    refute option.price.id == inactive.price.id
  end

  test "reauthorizes manage_billing and rejects malformed scopes" do
    fixture = BillingFixtures.create!()

    assert {:error, :billing_admin_required} =
             PlatformBilling.list_subscription_options(fixture.member_scope)

    assert {:error, :billing_admin_required} = PlatformBilling.list_subscription_options(nil)
  end

  defp subscription_options_fixture! do
    now = DateTime.utc_now(:microsecond)

    current = insert_option!("current", Factory.tstz_range(DateTime.add(now, -60)))
    future = insert_option!("future", Factory.tstz_range(DateTime.add(now, 86_400)))
    inactive = insert_option!("inactive", Factory.tstz_range(DateTime.add(now, -60)), "draft")

    {current, future, inactive}
  end

  defp insert_option!(suffix, valid_during, plan_status \\ "active") do
    plan =
      Repo.insert!(%Plan{
        code: "platform-#{suffix}-#{System.unique_integer([:positive])}",
        name: "Plano #{suffix}",
        status: plan_status
      })

    version =
      Repo.insert!(%PlanVersion{
        platform_plan_id: plan.id,
        version: 1,
        name: "Versão #{suffix}",
        description: "Plano SaaS para teste de opção tenant.",
        status: "published",
        published_at: DateTime.utc_now(:microsecond),
        inserted_at: DateTime.utc_now(:microsecond)
      })

    price =
      Repo.insert!(%Price{
        platform_plan_version_id: version.id,
        currency: "BRL",
        amount: Decimal.new("199.90"),
        billing_interval_unit: "month",
        billing_interval_count: 1,
        valid_during: valid_during,
        inserted_at: DateTime.utc_now(:microsecond)
      })

    %{plan: plan, version: version, price: price}
  end

  defp grant_polo_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end
end
