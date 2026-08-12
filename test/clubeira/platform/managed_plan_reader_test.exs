defmodule Clubeira.Platform.ManagedPlanReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.PlatformBilling
  alias Clubeira.Tenancy.ActorScope

  test "managed plan inventory requires a current platform billing role" do
    administrator = insert(:user)
    grant_platform_billing_admin!(administrator)
    administrator_scope = ActorScope.new!(administrator.id, uuid7())
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _plan} =
             PlatformBilling.publish_plan(
               administrator_scope,
               "restricted-#{uuid7()}",
               1,
               plan_attributes(now)
             )

    unauthorized = insert(:user)
    unauthorized_scope = ActorScope.new!(unauthorized.id, uuid7())

    assert {:error, :platform_billing_admin_required} =
             PlatformBilling.list_managed_plans(unauthorized_scope, %{})
  end

  test "managed inventory includes every immutable version and future price without changing the current catalog" do
    administrator = insert(:user)
    grant_platform_billing_admin!(administrator)
    scope = ActorScope.new!(administrator.id, uuid7())
    code = "managed-#{uuid7()}"
    now = DateTime.utc_now(:microsecond)
    future = DateTime.add(now, 86_400)

    assert {:ok, _current} =
             PlatformBilling.publish_plan(
               scope,
               code,
               1,
               plan_attributes(DateTime.add(now, -60), "Operação 2026", "399.90")
             )

    assert {:ok, _future} =
             PlatformBilling.publish_plan(
               scope,
               code,
               2,
               plan_attributes(future, "Operação 2027", "499.90")
             )

    assert {:ok,
            %{
              plans: [plan],
              page: %{limit: 20, has_more: false, next_cursor: nil}
            }} = PlatformBilling.list_managed_plans(scope, %{})

    assert plan.code == code
    assert plan.status == "active"
    assert Enum.map(plan.versions, & &1.version) == [2, 1]

    [future_version, current_version] = plan.versions
    assert future_version.status == "published"
    assert future_version.name == "Operação 2027"
    assert [%{key: "partner_limit", status: "active"}] = future_version.features
    assert [%{amount: amount, valid_during: valid_during}] = future_version.prices
    assert amount == Decimal.new("499.90")
    assert valid_during.lower == future

    assert current_version.name == "Operação 2026"

    assert {:ok, [%{code: ^code, version: %{version: 1}}]} =
             PlatformBilling.list_plans(scope)
  end

  test "managed plan inventory paginates stable plan identities with an opaque keyset cursor" do
    administrator = insert(:user)
    grant_platform_billing_admin!(administrator)
    scope = ActorScope.new!(administrator.id, uuid7())
    now = DateTime.utc_now(:microsecond)

    created =
      Enum.map(1..3, fn sequence ->
        code = "page-#{sequence}-#{uuid7()}"

        assert {:ok, plan} =
                 PlatformBilling.publish_plan(
                   scope,
                   code,
                   1,
                   plan_attributes(DateTime.add(now, -60))
                 )

        plan.id
      end)

    assert {:ok,
            %{
              plans: first_page,
              page: %{limit: 2, has_more: true, next_cursor: cursor}
            }} = PlatformBilling.list_managed_plans(scope, %{"limit" => "2"})

    assert is_binary(cursor)
    assert length(first_page) == 2

    assert {:ok,
            %{
              plans: second_page,
              page: %{limit: 2, has_more: false, next_cursor: nil}
            }} =
             PlatformBilling.list_managed_plans(scope, %{
               "limit" => "2",
               "after" => cursor
             })

    assert length(second_page) == 1

    returned_ids = Enum.map(first_page ++ second_page, & &1.id)
    assert MapSet.new(returned_ids) == MapSet.new(created)
    assert length(Enum.uniq(returned_ids)) == 3
  end

  defp grant_platform_billing_admin!(user) do
    now = DateTime.utc_now(:microsecond)

    organization =
      insert(:organization,
        kind: "platform",
        legal_name: "Clubeira Plataforma",
        trade_name: "Clubeira",
        status: "active"
      )

    role =
      insert(:organization_role,
        organization_id: organization.id,
        key: "platform_billing_admin",
        name: "Administração de billing da plataforma",
        status: "active"
      )

    membership =
      insert(:organization_membership,
        organization_id: organization.id,
        user_id: user.id,
        valid_during: tstz_range(DateTime.add(now, -60)),
        status: "active"
      )

    insert(:organization_membership_role,
      organization_id: organization.id,
      organization_membership_id: membership.id,
      organization_role_id: role.id,
      inserted_at: now
    )
  end

  defp plan_attributes(
         valid_from,
         version_name \\ "Operação 2026",
         amount \\ "399.90"
       ) do
    %{
      "name" => "Operação",
      "version_name" => version_name,
      "description" => "Plano operacional para polos em crescimento.",
      "features" => [
        %{
          "key" => "partner_limit",
          "name" => "Limite de parceiros",
          "value_kind" => "integer",
          "integer_value" => 250
        }
      ],
      "price" => %{
        "currency" => "BRL",
        "amount" => amount,
        "billing_interval_unit" => "month",
        "billing_interval_count" => 1,
        "valid_from" => DateTime.to_iso8601(valid_from),
        "valid_until" => DateTime.to_iso8601(DateTime.add(valid_from, 31_536_000))
      }
    }
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
