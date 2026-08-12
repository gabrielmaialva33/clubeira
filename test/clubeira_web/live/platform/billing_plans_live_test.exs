defmodule ClubeiraWeb.Platform.BillingPlansLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Factory
  alias Clubeira.Platform.Plan
  alias Clubeira.PlatformBilling
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-planos-da-plataforma"

  test "renders the complete managed inventory including future plan versions", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    actor_scope = ActorScope.new!(user.id, uuid7())
    code = "operacao-web-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _plan} =
             PlatformBilling.publish_plan(
               actor_scope,
               code,
               1,
               plan_attributes(DateTime.add(now, -60), "Operação 2026", "399.90")
             )

    assert {:ok, _plan} =
             PlatformBilling.publish_plan(
               actor_scope,
               code,
               2,
               plan_attributes(DateTime.add(now, 86_400), "Operação 2027", "499.90")
             )

    session = login!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    assert has_element?(view, "#platform-billing-plans-page")
    assert has_element?(view, "#platform-nav-billing[aria-current='page']")
    assert has_element?(view, "#managed-platform-plans[phx-update='stream']")
    assert has_element?(view, "[data-plan-code='#{code}']")
    assert has_element?(view, "[data-plan-code='#{code}'] [data-plan-version='2']")
    assert has_element?(view, "[data-plan-code='#{code}'] [data-feature-key='partner_limit']")
    assert has_element?(view, "[data-plan-code='#{code}'] [data-price-amount='499.90']")
    assert has_element?(view, "#platform-plan-publish-form")
  end

  test "publishes a complete plan version without accepting raw feature, price or status ids", %{
    conn: conn
  } do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)
    code = "novo-plano-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:second)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    refute has_element?(view, "#platform-plan-publish-form [name$='[platform_feature_id]']")
    refute has_element?(view, "#platform-plan-publish-form [name$='[platform_price_id]']")
    refute has_element?(view, "#platform-plan-publish-form [name$='[status]']")

    params = %{
      "code" => code,
      "version" => "1",
      "name" => "Plano Essencial",
      "version_name" => "Essencial 2026",
      "description" => "Plano inicial publicado pelo controle global.",
      "currency" => "BRL",
      "amount" => "149.90",
      "billing_interval_unit" => "month",
      "billing_interval_count" => "1",
      "valid_from" => DateTime.to_iso8601(now),
      "valid_until" => now |> DateTime.add(31_536_000) |> DateTime.to_iso8601(),
      "features" => %{
        "0" => %{
          "key" => "partner_limit_web",
          "name" => "Limite de parceiros web",
          "value_kind" => "integer",
          "integer_value" => "120"
        }
      }
    }

    view
    |> form("#platform-plan-publish-form", plan: params)
    |> render_submit()

    assert has_element?(view, "[data-plan-code='#{code}'] [data-status='active']")

    assert has_element?(
             view,
             "[data-plan-code='#{code}'] [data-plan-version='1'] [data-version-status='published']"
           )

    assert has_element?(view, "[data-plan-code='#{code}'] [data-feature-key='partner_limit_web']")
    assert has_element?(view, "[data-plan-code='#{code}'] [data-price-amount='149.90']")
  end

  test "revalidates the persisted platform billing role before publication", %{conn: conn} do
    user = Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(user)
    %{membership: billing_membership} = grant_platform_billing_admin!(user)
    session = login!(user)
    code = "revoked-before-publish-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:second)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    billing_membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    params = %{
      "code" => code,
      "version" => "1",
      "name" => "Plano não autorizado",
      "version_name" => "Versão não autorizada",
      "description" => "Esta publicação deve ser recusada após a revogação da role.",
      "currency" => "BRL",
      "amount" => "99.90",
      "billing_interval_unit" => "month",
      "billing_interval_count" => "1",
      "valid_from" => DateTime.to_iso8601(now),
      "valid_until" => now |> DateTime.add(31_536_000) |> DateTime.to_iso8601(),
      "features" => %{
        "0" => %{
          "key" => "revoked_limit",
          "name" => "Limite revogado",
          "value_kind" => "integer",
          "integer_value" => "1"
        }
      }
    }

    view
    |> form("#platform-plan-publish-form", plan: params)
    |> render_submit()

    assert_redirect(view, "/platform")
    refute Repo.get_by(Plan, code: code)
  end

  test "paginates managed plan identities with the opaque keyset cursor", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    actor_scope = ActorScope.new!(user.id, uuid7())
    now = DateTime.utc_now(:microsecond)

    Enum.each(1..3, fn sequence ->
      assert {:ok, _plan} =
               PlatformBilling.publish_plan(
                 actor_scope,
                 "web-page-#{sequence}-#{System.unique_integer([:positive])}",
                 1,
                 plan_attributes(DateTime.add(now, sequence), "Página #{sequence}", "99.90")
               )
    end)

    assert {:ok, %{plans: first_page, page: %{next_cursor: cursor}}} =
             PlatformBilling.list_managed_plans(actor_scope, %{"limit" => "2"})

    assert {:ok, %{plans: second_page}} =
             PlatformBilling.list_managed_plans(actor_scope, %{
               "limit" => "2",
               "after" => cursor
             })

    session = login!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans?limit=2")

    Enum.each(first_page, fn plan ->
      assert has_element?(view, "[data-plan-code='#{plan.code}']")
    end)

    assert has_element?(view, "#managed-platform-plans-next-page")
    view |> element("#managed-platform-plans-next-page") |> render_click()

    Enum.each(second_page, fn plan ->
      assert has_element?(view, "[data-plan-code='#{plan.code}']")
    end)

    Enum.each(first_page, fn plan ->
      refute has_element?(view, "[data-plan-code='#{plan.code}']")
    end)

    refute has_element?(view, "#managed-platform-plans-next-page")
  end

  test "adds and publishes multiple typed features through the request changeset", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)
    code = "typed-features-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:second)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    view |> element("#add-platform-plan-feature") |> render_click()
    assert has_element?(view, "#platform-plan-feature-1")

    common = %{
      "code" => code,
      "version" => "1",
      "name" => "Plano com features tipadas",
      "version_name" => "Features 2026",
      "description" => "Plano com limites inteiros e uma capacidade booleana.",
      "currency" => "BRL",
      "amount" => "249.90",
      "billing_interval_unit" => "month",
      "billing_interval_count" => "1",
      "valid_from" => DateTime.to_iso8601(now),
      "valid_until" => now |> DateTime.add(31_536_000) |> DateTime.to_iso8601()
    }

    change_params =
      Map.put(common, "features", %{
        "0" => %{
          "key" => "typed_partner_limit",
          "name" => "Limite tipado de parceiros",
          "value_kind" => "integer",
          "integer_value" => "200"
        },
        "1" => %{
          "key" => "typed_priority_support",
          "name" => "Suporte prioritário tipado",
          "value_kind" => "boolean",
          "integer_value" => "0"
        }
      })

    view
    |> form("#platform-plan-publish-form", plan: change_params)
    |> render_change()

    assert has_element?(view, "#platform-plan-feature-1 input[type='checkbox']")

    submit_params =
      put_in(change_params, ["features", "1"], %{
        "key" => "typed_priority_support",
        "name" => "Suporte prioritário tipado",
        "value_kind" => "boolean",
        "boolean_value" => "true"
      })

    view
    |> form("#platform-plan-publish-form", plan: submit_params)
    |> render_submit()

    assert has_element?(
             view,
             "[data-plan-code='#{code}'] [data-feature-key='typed_partner_limit']"
           )

    assert has_element?(
             view,
             "[data-plan-code='#{code}'] [data-feature-key='typed_priority_support']"
           )
  end

  test "keeps platform users without the billing capability out of the workspace", %{conn: conn} do
    user = Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(user)
    session = login!(user)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform"}}} =
             live(conn, "/platform/billing/plans")
  end

  test "rejects a malformed identity event without crashing the LiveView", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    render_submit(view, "publish_plan", %{
      "plan" => %{"code" => "malformed-identity", "version" => "not-a-version"}
    })

    assert has_element?(view, "#platform-plan-publish-form")
    refute Repo.get_by(Plan, code: "malformed-identity")
  end

  test "revalidates the persisted session before publication", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)
    code = "revoked-session-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    render_submit(view, "publish_plan", %{
      "plan" => %{"code" => code, "version" => "1"}
    })

    assert_redirect(view, "/platform/login")
    refute Repo.get_by(Plan, code: code)
  end

  test "clears a malformed managed-inventory cursor", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform/billing/plans"}}} =
             live(conn, "/platform/billing/plans?after=not-a-keyset-cursor")
  end

  test "refetches immutable inventory after a conflicting publication", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    actor_scope = ActorScope.new!(user.id, uuid7())
    code = "conflicting-version-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _plan} =
             PlatformBilling.publish_plan(
               actor_scope,
               code,
               1,
               plan_attributes(now, "Original 2026", "399.90")
             )

    session = login!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    conflicting_params = %{
      "code" => code,
      "version" => "1",
      "name" => "Operação",
      "version_name" => "Original 2026",
      "description" => "Tentativa divergente contra uma versão imutável.",
      "currency" => "BRL",
      "amount" => "777.00",
      "billing_interval_unit" => "month",
      "billing_interval_count" => "1",
      "valid_from" => DateTime.to_iso8601(now),
      "valid_until" => now |> DateTime.add(31_536_000) |> DateTime.to_iso8601(),
      "features" => %{
        "0" => %{
          "key" => "partner_limit",
          "name" => "Limite de parceiros",
          "value_kind" => "integer",
          "integer_value" => "250"
        }
      }
    }

    view
    |> form("#platform-plan-publish-form", plan: conflicting_params)
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "[data-plan-code='#{code}'] [data-price-amount='399.90']")
    refute has_element?(view, "[data-plan-code='#{code}'] [data-price-amount='777.00']")
  end

  test "keeps one typed feature row while adding and removing dynamic rows", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    assert has_element?(view, "#platform-plan-feature-0")
    refute has_element?(view, "#platform-plan-feature-1")

    view |> element("#add-platform-plan-feature") |> render_click()
    assert has_element?(view, "#platform-plan-feature-1")

    view |> element("#remove-platform-plan-feature-1") |> render_click()
    assert has_element?(view, "#platform-plan-feature-0")
    refute has_element?(view, "#platform-plan-feature-1")

    view |> element("#remove-platform-plan-feature-0") |> render_click()
    assert has_element?(view, "#platform-plan-feature-0")

    render_click(view, "remove_plan_feature", %{"index" => "not-an-index"})
    render_click(view, "remove_plan_feature", %{})
    assert has_element?(view, "#platform-plan-publish-form")
  end

  test "renders validation errors for incomplete and malformed publication events", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    session = login!(user)
    code = "incomplete-plan-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    render_submit(view, "publish_plan", %{
      "plan" => %{"code" => code, "version" => "1", "features" => []}
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-plan-publish-form p.text-red-600")
    refute Repo.get_by(Plan, code: code)

    render_submit(view, "publish_plan", %{})
    render_change(view, "validate_plan", %{})
    assert has_element?(view, "#platform-plan-publish-form")
  end

  test "renders boolean limits and annual prices from persisted plan semantics", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_billing_admin!(user)
    actor_scope = ActorScope.new!(user.id, uuid7())
    code = "annual-web-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    attributes = %{
      "name" => "Annual operation",
      "version_name" => "Annual 2026",
      "description" => "Annual plan with one disabled boolean capability.",
      "features" => [
        %{
          "key" => "priority_support",
          "name" => "Priority support",
          "value_kind" => "boolean",
          "boolean_value" => false
        }
      ],
      "price" => %{
        "currency" => "BRL",
        "amount" => "599.90",
        "billing_interval_unit" => "year",
        "billing_interval_count" => 2,
        "valid_from" => DateTime.to_iso8601(now),
        "valid_until" => DateTime.to_iso8601(DateTime.add(now, 63_072_000))
      }
    }

    assert {:ok, _plan} = PlatformBilling.publish_plan(actor_scope, code, 1, attributes)
    session = login!(user)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform/billing/plans")

    assert has_element?(view, "[data-feature-key='priority_support']", "Disabled")
    assert has_element?(view, "[data-price-amount='599.90']", "every 2 years")
  end

  defp grant_platform_billing_admin!(user) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        kind: "platform",
        legal_name: "Clubeira Plataforma",
        trade_name: "Clubeira",
        status: "active"
      )

    role =
      Factory.insert(:organization_role,
        organization_id: organization.id,
        key: "platform_billing_admin",
        name: "Administração de billing da plataforma",
        status: "active"
      )

    membership =
      Factory.insert(:organization_membership,
        organization_id: organization.id,
        user_id: user.id,
        valid_during: Factory.tstz_range(DateTime.add(now, -60)),
        status: "active"
      )

    assignment =
      Factory.insert(:organization_membership_role,
        organization_id: organization.id,
        organization_membership_id: membership.id,
        organization_role_id: role.id,
        inserted_at: now
      )

    %{organization: organization, role: role, membership: membership, assignment: assignment}
  end

  defp plan_attributes(valid_from, version_name, amount) do
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

  defp login!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
