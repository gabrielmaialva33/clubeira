defmodule ClubeiraWeb.Backoffice.ProductOfferingsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-os-planos-comerciais-web"

  test "lists only the selected polo offerings for a commercial admin", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#product-offerings-page")
    assert has_element?(view, "#product-offering-#{fixture.ids.product_offering}")
    refute has_element?(view, "#product-offering-#{other_polo.ids.product_offering}")
    assert has_element?(view, "#backoffice-nav-commercial[aria-current='page']")
  end

  test "publishes an offering from a published benefit and refreshes the inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    code = "clube-mensal-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    view
    |> form("#product-offering-publish-form",
      product_offering: %{
        code: code,
        name: "Clube Mensal",
        description: "Plano mensal com benefícios selecionados do polo.",
        renewal_policy: "automatic",
        cycle_policy: "calendar",
        cycle_interval_unit: "month",
        cycle_interval_count: "1",
        effective_from: DateTime.to_iso8601(fixture.now),
        effective_until: "",
        currency: "BRL",
        amount: "39.90",
        benefits: %{
          "0" => %{
            benefit_offer_version_id: fixture.ids.benefit_offer_version,
            allowance_per_cycle: "2",
            consumption_unit: "per_place"
          }
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#product-offerings-inventory [data-offering-code='#{code}']")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{product_offerings: [%{code: ^code, status: "active"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{"code" => code})
  end

  test "pauses an active offering through the domain lifecycle", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    view
    |> form("#product-offering-lifecycle-form-#{offering_id}",
      lifecycle: %{action: "pause", reason: "Pausa comercial planejada."}
    )
    |> render_submit()

    assert has_element?(view, "#product-offering-#{offering_id} [data-status='paused']")

    assert {:ok, %{product_offerings: [%{id: ^offering_id, status: "paused"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "code" => "offering-#{short_suffix(fixture.ids.polo)}"
             })
  end

  test "renders a draft offering identity that has no version yet", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    draft_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert {:ok, _draft} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               repo.insert(%ProductOffering{
                 id: draft_id,
                 polo_id: fixture.ids.polo,
                 access_product_version_id: fixture.ids.access_product_version,
                 code: "draft-offering-#{System.unique_integer([:positive])}",
                 scope_kind: "evergreen",
                 sales_channel: "direct",
                 status: "draft"
               })
             end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#product-offering-#{draft_id}")
    assert has_element?(view, "#product-offering-#{draft_id} [data-version-status='missing']")
  end

  test "rejects a lifecycle event for an offering outside the rendered inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}&code=not-rendered-offering")

    refute has_element?(view, "#product-offering-#{offering_id}")

    render_hook(view, "transition_product_offering", %{
      "offering_id" => offering_id,
      "lifecycle" => %{
        "action" => "pause",
        "reason" => "Evento forjado fora do inventário renderizado.",
        "idempotency_key" => "forged-offering-lifecycle"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{product_offerings: [%{id: ^offering_id, status: "active"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "code" => "offering-#{short_suffix(fixture.ids.polo)}"
             })
  end

  test "refetches an offering that changed before the submitted lifecycle decision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert {:ok, %{"status" => "paused"}} =
             Subscriptions.transition_product_offering(admin_scope, offering_id, %{
               action: "pause",
               reason: "Mudança concorrente antes da decisão web.",
               idempotency_key: "concurrent-offering-pause-#{Ecto.UUID.generate()}"
             })

    view
    |> form("#product-offering-lifecycle-form-#{offering_id}",
      lifecycle: %{action: "pause", reason: "Decisão web já obsoleta."}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#product-offering-#{offering_id} [data-status='paused']")
  end

  test "keeps an active offering unchanged for an invalid lifecycle decision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    render_hook(view, "transition_product_offering", %{
      "offering_id" => offering_id,
      "lifecycle" => %{
        "action" => "",
        "reason" => "",
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#product-offering-lifecycle-form-#{offering_id}")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{product_offerings: [%{id: ^offering_id, status: "active"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "code" => "offering-#{short_suffix(fixture.ids.polo)}"
             })
  end

  test "a revoked browser session cannot transition an offering", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#product-offering-lifecycle-form-#{offering_id}",
      lifecycle: %{action: "pause", reason: "A sessão revogada não pode alterar o lifecycle."}
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{product_offerings: [%{id: ^offering_id, status: "active"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "code" => "offering-#{short_suffix(fixture.ids.polo)}"
             })
  end

  test "applies inventory filters through canonical URL state while preserving the page size", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    code = "offering-#{short_suffix(fixture.ids.polo)}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}&limit=7")

    view
    |> form("#product-offering-filters", filters: %{status: "active", code: code})
    |> render_submit()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "polo" => fixture.polo_slug,
             "status" => "active",
             "code" => code,
             "limit" => "7"
           }

    assert has_element?(view, "#product-offering-#{fixture.ids.product_offering}")
  end

  test "rejects malformed offering browser events without mutating the inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    for {event, payload} <- [
          {"change_polo", %{}},
          {"filter", %{"filters" => "invalid"}},
          {"validate_product_offering", %{"product_offering" => "invalid"}},
          {"validate_product_offering", %{"product_offering" => %{"benefits" => "invalid"}}},
          {"publish_product_offering", %{"product_offering" => "invalid"}},
          {"transition_product_offering", %{"offering_id" => offering_id}}
        ] do
      render_hook(view, event, payload)
      assert has_element?(view, "#product-offerings-page")
    end

    assert has_element?(view, "#flash-error")

    assert {:ok, %{product_offerings: [%{id: ^offering_id, status: "active"}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "code" => "offering-#{short_suffix(fixture.ids.polo)}"
             })
  end

  test "canonicalizes invalid offering URL state instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/commercial/offerings?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               conn,
               "/admin/commercial/offerings?polo=#{fixture.polo_slug}&status=tampered"
             )
  end

  test "redirects a review-only moderator away from commercial offerings", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/commercial/offerings?polo=#{fixture.polo_slug}")
  end

  test "advances through the offering keyset without retaining the previous page", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    assert {:ok, _draft} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               repo.insert(%ProductOffering{
                 polo_id: fixture.ids.polo,
                 access_product_version_id: fixture.ids.access_product_version,
                 code: "pagination-offering-#{System.unique_integer([:positive])}",
                 scope_kind: "evergreen",
                 sales_channel: "direct",
                 status: "draft"
               })
             end)

    assert {:ok,
            %{
              product_offerings: [%{id: first_id}],
              page: %{has_more: true, next_cursor: cursor}
            }} = Subscriptions.list_product_offerings(admin_scope, %{"limit" => "1"})

    assert {:ok, %{product_offerings: [%{id: second_id}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{
               "limit" => "1",
               "after" => cursor
             })

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}&limit=1")

    assert has_element?(view, "#product-offering-#{first_id}")
    refute has_element?(view, "#product-offering-#{second_id}")

    view
    |> element("#product-offerings-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])
    assert has_element?(view, "#product-offering-#{second_id}")
    refute has_element?(view, "#product-offering-#{first_id}")
  end

  test "a revoked polo membership cannot mutate an offering", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.ids.product_offering

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.ids.polo), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    view
    |> form("#product-offering-lifecycle-form-#{offering_id}",
      lifecycle: %{action: "pause", reason: "Membership revogada não autoriza alteração."}
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")

    assert %{rows: [["active"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status FROM product_offerings WHERE id = $1",
               [offering_id]
             )
  end

  test "a forged polo switch remains bound to the current authorized polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(view, "/admin/commercial/offerings?polo=#{fixture.polo_slug}")
    assert has_element?(view, "#product-offering-#{fixture.ids.product_offering}")
  end

  test "keeps the publication form for invalid offering data", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    render_hook(view, "publish_product_offering", %{
      "product_offering" => %{"code" => "", "idempotency_key" => "short"}
    })

    assert has_element?(view, "#product-offering-publish-form")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{product_offerings: [%{id: offering_id}]}} =
             Subscriptions.list_product_offerings(admin_scope, %{})

    assert offering_id == fixture.ids.product_offering
  end

  test "renders a retired offering as terminal without lifecycle actions", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    offering_id = fixture.ids.product_offering

    assert {:ok, %{"status" => "retired"}} =
             Subscriptions.transition_product_offering(admin_scope, offering_id, %{
               action: "retire",
               reason: "Oferta encerrada definitivamente.",
               idempotency_key: "retire-offering-web-#{Ecto.UUID.generate()}"
             })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#product-offering-#{offering_id} [data-status='retired']")
    refute has_element?(view, "#product-offering-lifecycle-form-#{offering_id}")
  end

  test "disables publication when the polo has no published active benefit", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "UPDATE benefit_offers SET status = 'retired' WHERE id = $1",
               [fixture.ids.benefit_offer]
             )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/commercial/offerings?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#offering-publication-without-benefits")
    refute has_element?(view, "#product-offering-publish-form")
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp short_suffix(id), do: id |> String.replace("-", "") |> String.slice(-12, 12)
end
