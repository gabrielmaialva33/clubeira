defmodule Clubeira.Subscriptions.ContractLifecycleTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions

  test "a billing admin suspends and reactivates a contract with one immutable suspension period" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    contract = captured_contract!(fixture)

    suspend = %{
      "action" => "suspend",
      "reason" => "Inadimplência confirmada pelo financeiro",
      "idempotency_key" => "contract-suspension-#{uuid7()}"
    }

    assert {:ok, suspended} =
             Subscriptions.transition_contract(admin_scope, contract.id, suspend)

    assert suspended == %{
             "access_contract_id" => contract.id,
             "action" => "suspend",
             "previous_status" => "active",
             "status" => "suspended",
             "event_sequence" => 2,
             "transitioned_at" => suspended["transitioned_at"]
           }

    assert {:ok, ^suspended} =
             Subscriptions.transition_contract(admin_scope, contract.id, suspend)

    reactivate = %{
      "action" => "reactivate",
      "reason" => "Pendência financeira regularizada",
      "idempotency_key" => "contract-reactivation-#{uuid7()}"
    }

    assert {:ok, reactivated} =
             Subscriptions.transition_contract(admin_scope, contract.id, reactivate)

    assert reactivated["previous_status"] == "suspended"
    assert reactivated["status"] == "active"
    assert reactivated["event_sequence"] == 3

    invalid = %{
      "action" => "reactivate",
      "reason" => "Contrato já está ativo",
      "idempotency_key" => "invalid-contract-reactivation-#{uuid7()}"
    }

    assert {:error, :invalid_access_contract_transition} =
             Subscriptions.transition_contract(admin_scope, contract.id, invalid)

    assert {:error, :invalid_access_contract_transition} =
             Subscriptions.transition_contract(admin_scope, contract.id, invalid)

    assert {:error, :idempotency_conflict} =
             Subscriptions.transition_contract(admin_scope, contract.id, %{
               suspend
               | "reason" => "Mesmo comando, conteúdo divergente"
             })

    assert {:ok, %{rows: [["active", 1, 3, false, true, 2, 2]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               result =
                 repo.query!(
                   """
                   SELECT
                     contract.status,
                     count(DISTINCT suspension.id),
                     count(DISTINCT contract_event.id),
                     bool_or(upper_inf(suspension.suspended_during)),
                     bool_and(NOT upper_inf(suspension.suspended_during)),
                     count(DISTINCT domain_event.id),
                     count(DISTINCT audit.id)
                   FROM access_contracts AS contract
                   LEFT JOIN contract_suspensions AS suspension
                     ON suspension.polo_id = contract.polo_id
                    AND suspension.access_contract_id = contract.id
                   LEFT JOIN contract_events AS contract_event
                     ON contract_event.polo_id = contract.polo_id
                    AND contract_event.access_contract_id = contract.id
                   LEFT JOIN domain_events AS domain_event
                     ON domain_event.polo_id = contract.polo_id
                    AND domain_event.aggregate_type = 'access_contract'
                    AND domain_event.aggregate_id = contract.id
                    AND domain_event.event_type IN (
                      'subscription.suspended',
                      'subscription.reactivated'
                    )
                   LEFT JOIN tenant_audit_events AS audit
                     ON audit.polo_id = contract.polo_id
                    AND audit.resource_type = 'access_contract'
                    AND audit.resource_id = contract.id
                    AND audit.action IN (
                      'subscription.suspended',
                      'subscription.reactivated'
                    )
                   WHERE contract.id = $1
                   GROUP BY contract.status
                   """,
                   [Ecto.UUID.dump!(contract.id)]
                 )

               {:ok, result}
             end)
  end

  test "contract lifecycle is authorized inside the routed polo" do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()
    contract = captured_contract!(fixture)
    other_admin_scope = grant_admin!(other_fixture)

    assert {:error, :access_contract_not_found} =
             Subscriptions.transition_contract(other_admin_scope, contract.id, %{
               "action" => "suspend",
               "reason" => "Tentativa fora do polo",
               "idempotency_key" => "contract-cross-polo-#{uuid7()}"
             })

    assert {:error, :billing_admin_required} =
             Subscriptions.transition_contract(fixture.member_scope, contract.id, %{
               "action" => "suspend",
               "reason" => "Membro não administra contratos",
               "idempotency_key" => "contract-member-denied-#{uuid7()}"
             })
  end

  test "contract lifecycle rejects malformed boundary inputs" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)

    assert {:error, :access_contract_not_found} =
             Subscriptions.transition_contract(admin_scope, "not-a-uuid", %{
               "action" => "suspend",
               "reason" => "Contrato inexistente",
               "idempotency_key" => "invalid-contract-id"
             })

    assert {:error, %Ecto.Changeset{}} =
             Subscriptions.transition_contract(admin_scope, uuid7(), %{})

    assert {:error, :billing_admin_required} =
             Subscriptions.transition_contract(nil, uuid7(), %{})
  end

  defp captured_contract!(fixture) do
    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    contract
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
