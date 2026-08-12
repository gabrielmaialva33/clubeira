defmodule ClubeiraWeb.Backoffice.AgreementsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.BillingFixtures
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.Partnerships
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-convenios-web"

  test "lists only selected-polo agreements and selectable references", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    other_admin = ReviewsFixtures.grant_moderator!(polo_fixture(other_fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede local")
    other_graph = agreement_graph!(other_fixture, "Rede remota")

    assert {:ok, %{agreement: agreement}} =
             Partnerships.publish_agreement(
               admin_scope,
               agreement_attributes(fixture, graph, "LOCAL")
             )

    assert {:ok, %{agreement: other_agreement}} =
             Partnerships.publish_agreement(
               other_admin,
               agreement_attributes(other_fixture, other_graph, "REMOTE")
             )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#agreements-page")
    assert has_element?(view, "#partner-agreement-#{agreement["id"]}")
    refute has_element?(view, "#partner-agreement-#{other_agreement["id"]}")

    assert has_element?(
             view,
             "#agreement-organization-ids option[value='#{graph.organization.id}']"
           )

    refute has_element?(
             view,
             "#agreement-organization-ids option[value='#{other_graph.organization.id}']"
           )

    assert has_element?(view, "#backoffice-nav-partners[aria-current='page']")
  end

  test "publishes a complete agreement from authorized options", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede gastronômica")
    session = authenticate!(admin_scope.actor_user_id)
    number = "WEB-#{uuid7() |> String.slice(-8, 8) |> String.upcase()}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    view
    |> form("#agreement-publish-form",
      agreement: %{
        agreement_number: number,
        name: "Convênio gastronômico web",
        valid_from: DateTime.to_iso8601(DateTime.add(graph.now, -60)),
        valid_until: DateTime.to_iso8601(DateTime.add(graph.now, 365 * 86_400)),
        signed_at: DateTime.to_iso8601(graph.now),
        settlement_model: "revenue_share",
        redemption_sla_seconds: "45",
        organization_ids: [graph.organization.id],
        brand_ids: [graph.brand.id],
        polo_place_ids: [fixture.polo_place.id],
        edition_ids: [graph.edition.id],
        benefit_offer_version_ids: [graph.benefit_offer_version_id]
      }
    )
    |> render_submit()

    assert has_element?(view, "#agreements-inventory [data-agreement-number='#{number}']")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{agreements: [%{"agreement_number" => ^number}]}} =
             Partnerships.list_agreements(admin_scope, %{"status" => "active"})
  end

  test "a revoked browser session cannot publish an agreement", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede sem sessão")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    attributes =
      fixture
      |> agreement_attributes(graph, "REVOKED")
      |> Map.delete("idempotency_key")

    view
    |> form("#agreement-publish-form", agreement: attributes)
    |> render_submit()

    assert_redirect(view, "/admin/login")
    assert {:ok, %{agreements: []}} = Partnerships.list_agreements(admin_scope, %{})
  end

  test "rejects a forged agreement reference from another polo and reloads authorized options", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede autorizada")
    other_graph = agreement_graph!(other_fixture, "Rede de outro polo")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    forged_attributes =
      fixture
      |> agreement_attributes(graph, "FORGED")
      |> Map.put("organization_ids", [other_graph.organization.id])

    render_hook(view, "publish_agreement", %{"agreement" => forged_attributes})

    assert has_element?(view, "#flash-error")

    assert has_element?(
             view,
             "#agreement-organization-ids option[value='#{graph.organization.id}']"
           )

    refute has_element?(
             view,
             "#agreement-organization-ids option[value='#{other_graph.organization.id}']"
           )

    assert {:ok, %{agreements: []}} = Partnerships.list_agreements(admin_scope, %{})
  end

  test "keeps the publication form and data unchanged for an invalid agreement", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    _graph = agreement_graph!(fixture, "Rede disponível para validação")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    render_hook(view, "publish_agreement", %{
      "agreement" => %{
        "agreement_number" => "",
        "name" => "",
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#agreement-publish-form")
    assert has_element?(view, "#flash-error")
    assert {:ok, %{agreements: []}} = Partnerships.list_agreements(admin_scope, %{})
  end

  test "redirects an operator without partner-management capability", %{conn: conn} do
    fixture = BillingFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture))
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_route.slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/partners/agreements?polo=#{fixture.polo_route.slug}")
  end

  test "canonicalizes invalid agreement URL state", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/partners/agreements?polo=#{fixture.polo_route.slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               conn,
               "/admin/partners/agreements?polo=#{fixture.polo_route.slug}&status=tampered"
             )
  end

  test "keeps URL and inventory server-bound for malformed browser events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede de eventos")

    assert {:ok, %{agreement: agreement}} =
             Partnerships.publish_agreement(
               admin_scope,
               agreement_attributes(fixture, graph, "EVENTS")
             )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})
    assert_patch(view, "/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{})
    assert has_element?(view, "#flash-error")

    render_submit(view, "filter", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "publish_agreement", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#partner-agreement-#{agreement["id"]}")
  end

  test "filters and advances through the agreement keyset cursor", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede paginada")

    agreements =
      for prefix <- ["PAGE-A", "PAGE-B"] do
        assert {:ok, %{agreement: agreement}} =
                 Partnerships.publish_agreement(
                   admin_scope,
                   agreement_attributes(fixture, graph, prefix)
                 )

        agreement
      end

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}&limit=1")

    view
    |> form("#agreement-filters", filters: %{status: "active"})
    |> render_submit()

    filter_path = assert_patch(view)
    filter_query = filter_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert filter_query == %{
             "limit" => "1",
             "polo" => fixture.polo_route.slug,
             "status" => "active"
           }

    assert has_element?(view, "#agreements-next-page")

    first_page_ids =
      Enum.filter(agreements, &has_element?(view, "#partner-agreement-#{&1["id"]}"))

    assert length(first_page_ids) == 1

    view
    |> element("#agreements-next-page")
    |> render_click()

    next_path = assert_patch(view)
    next_query = next_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert next_query["limit"] == "1"
    assert next_query["status"] == "active"
    assert is_binary(next_query["after"])
    refute has_element?(view, "#partner-agreement-#{hd(first_page_ids)["id"]}")
    refute has_element?(view, "#agreements-next-page")
  end

  test "rejects a signature outside the agreement validity", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede com assinatura inválida")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    attributes =
      fixture
      |> agreement_attributes(graph, "INVALID-SIGNATURE")
      |> Map.put("signed_at", DateTime.to_iso8601(DateTime.add(graph.now, 400 * 86_400)))

    render_hook(view, "publish_agreement", %{"agreement" => attributes})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#agreement-publish-form")
    assert {:ok, %{agreements: []}} = Partnerships.list_agreements(admin_scope, %{})
  end

  test "surfaces an agreement-number conflict without replacing the form", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede duplicada")
    original = agreement_attributes(fixture, graph, "DUPLICATE")

    assert {:ok, %{agreement: _agreement}} =
             Partnerships.publish_agreement(admin_scope, original)

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    duplicate = Map.put(original, "idempotency_key", "duplicate-agreement-number-web")
    render_hook(view, "publish_agreement", %{"agreement" => duplicate})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#agreement-publish-form")
  end

  test "reauthorizes the partner-management role before publication", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede com acesso revogado")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    revoke_membership!(fixture.polo.id, admin_scope.actor_user_id)

    render_hook(view, "publish_agreement", %{
      "agreement" => agreement_attributes(fixture, graph, "REVOKED-ROLE")
    })

    assert_redirect(view, "/admin?polo=#{fixture.polo_route.slug}")
  end

  test "renders suspended and terminated settlement semantics", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(polo_fixture(fixture), role_key: "admin")
    graph = agreement_graph!(fixture, "Rede de status")

    agreements =
      for {prefix, status, model} <- [
            {"SUSPENDED", "suspended", "fixed"},
            {"TERMINATED", "terminated", "none"},
            {"EXPIRED", "expired", "none"}
          ] do
        assert {:ok, %{agreement: agreement}} =
                 Partnerships.publish_agreement(
                   admin_scope,
                   fixture
                   |> agreement_attributes(graph, prefix)
                   |> Map.put("settlement_model", model)
                 )

        update_agreement_status!(fixture, agreement["id"], status)
        {agreement["id"], status, model}
      end

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners/agreements?polo=#{fixture.polo_route.slug}")

    for {agreement_id, status, model} <- agreements do
      assert has_element?(view, "#partner-agreement-#{agreement_id}", String.capitalize(status))

      expected_model = if model == "fixed", do: "Fixed", else: "No settlement"
      assert has_element?(view, "#partner-agreement-#{agreement_id}", expected_model)
    end
  end

  defp agreement_graph!(fixture, organization_name) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        legal_name: "#{organization_name} Ltda.",
        trade_name: organization_name
      )

    brand = Factory.insert(:brand)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.polo_place.place_id),
      organization: organization
    )

    Factory.insert(:brand_ownership,
      brand: brand,
      organization: organization,
      valid_during: Factory.tstz_range(DateTime.add(now, -3_600))
    )

    assert {:ok, edition} =
             Repo.transact_in_polo(fixture.service_scope, fn ->
               {:ok, Factory.insert(:edition, polo: fixture.polo)}
             end)

    benefit_offer_version_id =
      fixture.package_items
      |> hd()
      |> Map.fetch!(:benefit_offer_version_id)

    %{
      now: now,
      organization: organization,
      brand: brand,
      edition: edition,
      benefit_offer_version_id: benefit_offer_version_id
    }
  end

  defp agreement_attributes(fixture, graph, prefix) do
    %{
      "agreement_number" => "#{prefix}-#{String.slice(uuid7(), -8, 8)}",
      "name" => "Convênio #{prefix}",
      "valid_from" => DateTime.to_iso8601(DateTime.add(graph.now, -60)),
      "valid_until" => DateTime.to_iso8601(DateTime.add(graph.now, 365 * 86_400)),
      "signed_at" => DateTime.to_iso8601(graph.now),
      "settlement_model" => "revenue_share",
      "redemption_sla_seconds" => 45,
      "organization_ids" => [graph.organization.id],
      "brand_ids" => [graph.brand.id],
      "polo_place_ids" => [fixture.polo_place.id],
      "edition_ids" => [graph.edition.id],
      "benefit_offer_version_ids" => [graph.benefit_offer_version_id],
      "idempotency_key" => "agreement-#{uuid7()}"
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp polo_fixture(fixture) do
    %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope}
  end

  defp revoke_membership!(polo_id, user_id) do
    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(polo_id), Ecto.UUID.dump!(user_id)]
      )
    end)
  end

  defp update_agreement_status!(fixture, agreement_id, status) do
    assert {:ok, _updated} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               repo.query!("UPDATE partner_agreements SET status = $2 WHERE id = $1", [
                 Ecto.UUID.dump!(agreement_id),
                 status
               ])

               {:ok, agreement_id}
             end)
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
