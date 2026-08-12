defmodule ClubeiraWeb.Backoffice.BenefitOffersLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Catalog
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-o-catalogo-comercial-web"

  test "lists only the selected polo benefit offers for a commercial admin", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#benefit-offers-page")
    assert has_element?(view, "#benefit-offer-#{fixture.ids.benefit_offer}")
    refute has_element?(view, "#benefit-offer-#{other_polo.ids.benefit_offer}")
    assert has_element?(view, "#backoffice-nav-commercial[aria-current='page']")
  end

  test "publishes a percentage benefit at an authorized place and refreshes the inventory", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    code = "jantar-especial-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    view
    |> form("#benefit-offer-publish-form",
      benefit_offer: benefit_attributes(fixture, code)
    )
    |> render_submit()

    assert has_element?(view, "#benefit-offers-inventory [data-offer-code='#{code}']")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{benefit_offers: [%{code: ^code, status: "active"}]}} =
             Catalog.list_benefit_offers(admin_scope, %{"code" => code})
  end

  test "renders a draft benefit identity that has no version yet", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    draft_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert {:ok, _draft} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               repo.insert(%BenefitOffer{
                 id: draft_id,
                 polo_id: fixture.ids.polo,
                 code: "draft-without-version-#{System.unique_integer([:positive])}",
                 name: "Benefício em preparação",
                 benefit_kind: "custom",
                 status: "draft"
               })
             end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#benefit-offer-#{draft_id}")
    assert has_element?(view, "#benefit-offer-#{draft_id} [data-version-status='missing']")
  end

  test "a revoked browser session cannot publish a benefit offer", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    code = "revoked-session-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    render_hook(view, "publish_benefit_offer", %{
      "benefit_offer" => %{"code" => code}
    })

    assert_redirect(view, "/admin/login")

    assert {:ok, %{benefit_offers: []}} =
             Catalog.list_benefit_offers(admin_scope, %{"code" => code})
  end

  test "does not publish after the selected place becomes inactive", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    code = "inactive-place-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert {:ok, _polo_place} =
             Repo.transact_in_polo(fixture.scope, fn ->
               PoloPlace
               |> Repo.get!(fixture.ids.polo_place)
               |> Ecto.Changeset.change(status: "suspended")
               |> Repo.update()
             end)

    view
    |> form("#benefit-offer-publish-form",
      benefit_offer: benefit_attributes(fixture, code)
    )
    |> render_submit()

    assert_redirect(view, "/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert {:ok, %{benefit_offers: []}} =
             Catalog.list_benefit_offers(admin_scope, %{"code" => code})
  end

  test "keeps the publication form for invalid benefit data", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    render_hook(view, "publish_benefit_offer", %{
      "benefit_offer" => %{"code" => "", "idempotency_key" => "short"}
    })

    assert has_element?(view, "#benefit-offer-publish-form")
    assert has_element?(view, "#flash-error")
  end

  test "redirects an operator without commercial-management capability", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/commercial/benefits?polo=#{fixture.polo_slug}")
  end

  test "canonicalizes invalid catalog URL state", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/commercial/benefits?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/commercial/benefits?polo=#{fixture.polo_slug}&status=tampered")
  end

  test "keeps URL and inventory server-bound for malformed browser events", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})
    assert_patch(view, "/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{})
    assert has_element?(view, "#flash-error")

    render_submit(view, "filter", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "select_benefit_place", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "publish_benefit_offer", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#benefit-offer-#{fixture.ids.benefit_offer}")
  end

  test "filters by code and advances through the keyset cursor", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    draft_id = insert_draft_offer!(fixture)

    assert {:ok, %{benefit_offers: offers}} =
             Catalog.list_benefit_offers(admin_scope, %{"limit" => "100"})

    existing = Enum.find(offers, &(&1.id == fixture.ids.benefit_offer))
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, filter_view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}&limit=1")

    filter_view
    |> form("#benefit-offer-filters", filters: %{status: "", code: existing.code})
    |> render_submit()

    patched_path = assert_patch(filter_view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "code" => existing.code,
             "limit" => "1",
             "polo" => fixture.polo_slug
           }

    {:ok, page_view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}&limit=1")

    assert has_element?(page_view, "#benefit-offers-next-page")

    page_view
    |> element("#benefit-offers-next-page")
    |> render_click()

    next_path = assert_patch(page_view)
    next_query = next_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert next_query["limit"] == "1"
    assert is_binary(next_query["after"])

    assert has_element?(page_view, "#benefit-offer-#{fixture.ids.benefit_offer}") or
             has_element?(page_view, "#benefit-offer-#{draft_id}")

    refute has_element?(page_view, "#benefit-offers-next-page")
  end

  test "requires an active place before publication", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    assert {:ok, _polo_place} =
             Repo.transact_in_polo(fixture.scope, fn ->
               PoloPlace
               |> Repo.get!(fixture.ids.polo_place)
               |> Ecto.Changeset.change(status: "suspended")
               |> Repo.update()
             end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#benefit-publication-without-place")

    render_hook(view, "publish_benefit_offer", %{
      "benefit_offer" => %{"code" => "must-have-place"}
    })

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#benefit-offer-publish-form")
  end

  test "selects only a rendered place and reauthorizes before publication", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    render_change(view, "select_benefit_place", %{
      "place" => %{"id" => fixture.ids.place}
    })

    assert has_element?(
             view,
             "#benefit-place-form select option[value='#{fixture.ids.place}'][selected]"
           )

    render_hook(view, "select_benefit_place", %{"place" => %{"id" => Ecto.UUID.generate()}})
    assert has_element?(view, "#flash-error")

    revoke_membership!(fixture.ids.polo, admin_scope.actor_user_id)

    view
    |> form("#benefit-offer-publish-form",
      benefit_offer: benefit_attributes(fixture, "revoked-commercial-role")
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")
  end

  test "renders fixed-amount and retired benefit semantics", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:ok, %{"offer" => %{"id" => amount_offer_id}}} =
             Catalog.publish_benefit_offer(admin_scope, fixture.ids.place, %{
               offer: %{
                 code: "fixed-amount-web",
                 name: "Crédito de vinte e cinco reais",
                 benefit_kind: "discount_amount"
               },
               version: %{
                 title: "Crédito no estabelecimento",
                 description: "Crédito fixo para consumo do associado.",
                 terms: "Um uso por ciclo.",
                 redemption_instructions: "Apresente antes de fechar a conta.",
                 amount_value: "25.50",
                 currency: "BRL",
                 effective_during: %{starts_at: DateTime.add(fixture.now, -60), ends_at: nil}
               },
               idempotency_key: "fixed-amount-web-publication"
             })

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE benefit_offers SET status = 'retired' WHERE id = $1",
      [amount_offer_id]
    )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/benefits?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#benefit-offer-#{amount_offer_id}", "BRL 25.50")
    assert has_element?(view, "#benefit-offer-#{amount_offer_id}", "Retired")
  end

  defp benefit_attributes(fixture, code) do
    %{
      code: code,
      name: "Jantar especial",
      benefit_kind: "discount_percentage",
      title: "12,5% no jantar",
      description: "Desconto aplicado ao jantar do associado.",
      terms: "Um uso por ciclo durante a vigência.",
      redemption_instructions: "Apresente o voucher antes de fechar a conta.",
      percentage_value: "12.5",
      amount_value: "",
      currency: "",
      effective_from: DateTime.to_iso8601(fixture.now),
      effective_until: ""
    }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp insert_draft_offer!(fixture) do
    draft_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert {:ok, _draft} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               repo.insert(%BenefitOffer{
                 id: draft_id,
                 polo_id: fixture.ids.polo,
                 code: "pagination-draft-#{System.unique_integer([:positive])}",
                 name: "Benefício paginado",
                 benefit_kind: "custom",
                 status: "draft"
               })
             end)

    draft_id
  end

  defp revoke_membership!(polo_id, user_id) do
    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(polo_id), Ecto.UUID.dump!(user_id)]
      )
    end)
  end
end
