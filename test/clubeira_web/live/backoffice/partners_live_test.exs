defmodule ClubeiraWeb.Backoffice.PartnersLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Directory
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-parceiros-web"

  test "lists only partner accesses from the selected polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    other_admin = ReviewsFixtures.grant_moderator!(other_fixture, role_key: "admin")
    {access, _partner} = grant_access!(fixture, admin_scope)
    {other_access, _other_partner} = grant_access!(other_fixture, other_admin)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#partners-page")
    assert has_element?(view, "#partner-access-#{access["id"]}")
    refute has_element?(view, "#partner-access-#{other_access["id"]}")
    assert has_element?(view, "#backoffice-nav-partners[aria-current='page']")
  end

  test "grants and revokes a verified partner account through domain commands", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    ensure_operator!(fixture)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    view
    |> form("#partner-access-grant-form",
      place_id: fixture.ids.place,
      partner_access: %{email: partner.email}
    )
    |> render_submit()

    assert {:ok, %{partner_accesses: [%{id: access_id, status: "active"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})

    assert has_element?(view, "#partner-access-#{access_id}[data-status='active']")

    view
    |> form("#partner-access-revoke-form-#{access_id}",
      revocation: %{reason: "Responsável desligado da operação."}
    )
    |> render_submit()

    assert has_element?(view, "#partner-access-#{access_id}[data-status='revoked']")

    assert {:ok, %{partner_accesses: [%{id: ^access_id, status: "revoked"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})
  end

  test "onboards an organization and its first place atomically", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    slug = "sabores-web-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    view
    |> form("#partner-onboarding-form",
      onboarding: %{
        legal_name: "Sabores da Serra Alimentos Ltda.",
        trade_name: "Sabores da Serra",
        cnpj: "12.ABC.345/01DE-35",
        place_name: "Sabores da Serra Centro",
        place_slug: slug,
        postal_code: "12.345-678",
        street: "Rua das Flores",
        number: "120",
        complement: "Loja 2",
        district: "Centro"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info")

    assert {:ok, %{places: places}} =
             Directory.list_backoffice_places(admin_scope, %{
               "status" => "active",
               "limit" => "100"
             })

    assert Enum.any?(places, &(&1.place.slug == slug))
    assert has_element?(view, "#partner-access-place-id option", "Sabores da Serra Centro")
  end

  test "rejects revocation for a partner access outside the rendered inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}&email=absent@example.test")

    refute has_element?(view, "#partner-access-#{access["id"]}")

    render_hook(view, "revoke_partner_access", %{
      "access_id" => access["id"],
      "revocation" => %{
        "reason" => "Evento forjado fora do inventário renderizado.",
        "idempotency_key" => "forged-partner-revocation"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: [%{id: access_id, status: "active"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})

    assert access_id == access["id"]
  end

  test "refetches partner access that another operator already revoked", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    access_id = access["id"]
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    assert {:ok, _revocation} =
             Directory.revoke_partner_access(admin_scope, access_id, %{
               reason: "Revogação concorrente válida.",
               idempotency_key: "concurrent-partner-revocation-#{uuid7()}"
             })

    view
    |> form("#partner-access-revoke-form-#{access_id}",
      revocation: %{reason: "Decisão web já obsoleta."}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#partner-access-#{access_id}[data-status='revoked']")
    refute has_element?(view, "#partner-access-revoke-form-#{access_id}")

    assert {:ok, %{partner_accesses: [%{id: ^access_id, status: "revoked"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})
  end

  test "a revoked browser session cannot onboard a partner", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    slug = "revoked-session-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    render_hook(view, "onboard_partner", %{
      "onboarding" => %{"legal_name" => "Não cria Ltda.", "place_slug" => slug}
    })

    assert_redirect(view, "/admin/login")

    assert {:ok, %{places: places}} =
             Directory.list_backoffice_places(admin_scope, %{
               "status" => "active",
               "limit" => "100"
             })

    refute Enum.any?(places, &(&1.place.slug == slug))
  end

  test "applies partner filters through canonical URL state while preserving the page size", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}&limit=7")

    view
    |> form("#partner-access-filters", filters: %{status: "active", email: partner.email})
    |> render_submit()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "polo" => fixture.polo_slug,
             "status" => "active",
             "email" => partner.email,
             "limit" => "7"
           }

    assert has_element?(view, "#partner-access-#{access["id"]}")
  end

  test "rejects malformed partner browser events without mutating access", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    for {event, payload} <- [
          {"change_polo", %{}},
          {"filter", %{"filters" => "invalid"}},
          {"onboard_partner", %{"onboarding" => "invalid"}},
          {"grant_partner_access", %{"place_id" => fixture.ids.place}},
          {"revoke_partner_access", %{"access_id" => access["id"]}}
        ] do
      render_hook(view, event, payload)
      assert has_element?(view, "#partners-page")
    end

    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: [%{id: access_id, status: "active"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})

    assert access_id == access["id"]
  end

  test "canonicalizes invalid partner URL state instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/partners?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/partners?polo=#{fixture.polo_slug}&status=tampered")
  end

  test "redirects a review-only moderator away from partner management", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/partners?polo=#{fixture.polo_slug}")
  end

  test "a forged polo switch remains bound to the current authorized polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, _partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(view, "/admin/partners?polo=#{fixture.polo_slug}")
    assert has_element?(view, "#partner-access-#{access["id"]}")
  end

  test "advances through the partner-access keyset without retaining the previous page", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    ensure_operator!(fixture)

    for suffix <- ["first", "second"] do
      partner =
        Factory.insert(:user,
          email: "partner-pagination-#{suffix}-#{uuid7()}@example.test",
          email_verified_at: DateTime.utc_now(:microsecond)
        )

      assert {:ok, _access} =
               Directory.grant_partner_access(admin_scope, fixture.ids.place, %{
                 "email" => partner.email,
                 "idempotency_key" => "partner-pagination-#{suffix}-#{uuid7()}"
               })
    end

    assert {:ok,
            %{
              partner_accesses: [%{id: first_id}],
              page: %{has_more: true, next_cursor: cursor}
            }} = Directory.list_backoffice_partner_accesses(admin_scope, %{"limit" => "1"})

    assert {:ok, %{partner_accesses: [%{id: second_id}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{
               "limit" => "1",
               "after" => cursor
             })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}&limit=1")

    assert has_element?(view, "#partner-access-#{first_id}")
    refute has_element?(view, "#partner-access-#{second_id}")

    view
    |> element("#partner-accesses-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])
    assert has_element?(view, "#partner-access-#{second_id}")
    refute has_element?(view, "#partner-access-#{first_id}")
  end

  test "keeps the onboarding form for invalid partner and place data", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "onboard_partner", %{
      "onboarding" => %{
        "legal_name" => "",
        "cnpj" => "invalid",
        "place_name" => "",
        "place_slug" => "invalid slug",
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#partner-onboarding-form")
    assert has_element?(view, "#flash-error")
  end

  test "keeps the grant form when partner access data is invalid", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    ensure_operator!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "grant_partner_access", %{
      "place_id" => fixture.ids.place,
      "partner_access" => %{"email" => "invalid", "idempotency_key" => "short"}
    })

    assert has_element?(view, "#partner-access-grant-form")
    assert has_element?(view, "#flash-error")
  end

  test "rejects access for an email without a verified active account", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    ensure_operator!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    email = "missing-partner-#{uuid7()}@example.test"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "grant_partner_access", %{
      "place_id" => fixture.ids.place,
      "partner_access" => %{
        "email" => email,
        "idempotency_key" => "missing-partner-#{uuid7()}"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: []}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => email})
  end

  test "rejects a forged place outside the rendered partner workspace", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "grant_partner_access", %{
      "place_id" => uuid7(),
      "partner_access" => %{
        "email" => partner.email,
        "idempotency_key" => "forged-place-#{uuid7()}"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: []}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})
  end

  test "keeps one partner membership when access is granted twice", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "grant_partner_access", %{
      "place_id" => fixture.ids.place,
      "partner_access" => %{
        "email" => partner.email,
        "idempotency_key" => "duplicate-partner-#{uuid7()}"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: [%{id: access_id, status: "active"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})

    assert access_id == access["id"]
  end

  test "renders an invited partner without offering revocation", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, _partner} = grant_access!(fixture, admin_scope)

    TestDatabaseRole.as_owner(fn ->
      Repo.query!("UPDATE polo_memberships SET status = 'invited' WHERE id = $1", [
        Ecto.UUID.dump!(access["id"])
      ])
    end)

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#partner-access-#{access["id"]}[data-status='invited']")
    refute has_element?(view, "#partner-access-revoke-form-#{access["id"]}")
  end

  test "keeps the active access when revocation data is invalid", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    render_hook(view, "revoke_partner_access", %{
      "access_id" => access["id"],
      "revocation" => %{"reason" => "", "idempotency_key" => "short"}
    })

    assert has_element?(view, "#partner-access-revoke-form-#{access["id"]}")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{partner_accesses: [%{status: "active"}]}} =
             Directory.list_backoffice_partner_accesses(admin_scope, %{"email" => partner.email})
  end

  test "a revoked polo membership cannot revoke partner access", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    {access, _partner} = grant_access!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/partners?polo=#{fixture.polo_slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.ids.polo), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    view
    |> form("#partner-access-revoke-form-#{access["id"]}",
      revocation: %{reason: "Membership revogada não autoriza esta decisão."}
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")

    assert %{rows: [["active"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status FROM polo_memberships WHERE id = $1",
               [access["id"]]
             )
  end

  defp grant_access!(fixture, admin_scope) do
    ensure_operator!(fixture)
    partner = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))

    assert {:ok, access} =
             Directory.grant_partner_access(admin_scope, fixture.ids.place, %{
               "email" => partner.email,
               "idempotency_key" => "partner-web-grant-#{uuid7()}"
             })

    {access, partner}
  end

  defp ensure_operator!(fixture) do
    organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
