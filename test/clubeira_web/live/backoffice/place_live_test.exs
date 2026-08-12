defmodule ClubeiraWeb.Backoffice.PlaceLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-detalhe-do-estabelecimento"

  test "an authorized admin opens one place detail inside the selected polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#place-detail")
    assert has_element?(view, "#place-detail-name")
    assert has_element?(view, "#place-detail-status[data-status='active']")
    assert has_element?(view, "#place-detail-revision", "1")
    assert has_element?(view, "#backoffice-nav-places[aria-current='page']")
  end

  test "renders the published profile summary", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    insert_profile!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#place-detail", "operacao@example.test")
    assert has_element?(view, "#place-detail", "+5511999990000")
  end

  test "renders the complete profile editor from the persisted read model", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    cafe = Factory.insert(:place_category, key: "cafe", name: "Cafe", display_order: 10)

    restaurant =
      Factory.insert(:place_category,
        key: "restaurant",
        name: "Restaurante",
        display_order: 20
      )

    assert {:ok, _profile} =
             Directory.publish_place_profile(admin_scope, fixture.ids.place, %{
               contact: %{email: "painel@perfil.example", phone: "+5588999990101"},
               category_keys: [restaurant.key, cafe.key],
               weekly_hours: [
                 %{weekday: 1, opens_at: "09:00", closes_at: "18:00"},
                 %{weekday: 6, opens_at: "20:00", closes_at: "02:00"}
               ],
               special_hours: [
                 %{date: "2026-12-25", kind: "closed"},
                 %{
                   date: "2026-12-31",
                   kind: "custom",
                   windows: [
                     %{opens_at: "18:00", closes_at: "22:00"},
                     %{opens_at: "23:00", closes_at: "02:00"}
                   ]
                 }
               ],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "place-live-complete-profile"
             })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#place-profile-form")
    assert has_element?(view, "#place-profile-revision", "1")
    assert has_element?(view, "#profile_public_email[value='painel@perfil.example']")
    assert has_element?(view, "#profile_public_phone[value='+5588999990101']")
    assert has_element?(view, "#profile_category_keys option[value='cafe'][selected]")
    assert has_element?(view, "#profile_category_keys option[value='restaurant'][selected]")
    assert has_element?(view, "#profile_weekly_hours_0_weekday option[value='1'][selected]")
    assert has_element?(view, "#profile_weekly_hours_1_closes_at[value='02:00:00']")
    assert has_element?(view, "#profile_special_hours_0_local_date[value='2026-12-25']")
    assert has_element?(view, "#profile_special_hours_1_windows_1_opens_at[value='23:00:00']")
  end

  test "publishes a missing profile and reloads its complete revision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    Factory.insert(:place_category, key: "cafe", name: "Cafe")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    view
    |> form("#place-profile-form",
      profile: %{
        public_email: "novo@perfil.example",
        public_phone: "(88) 99999-0101",
        category_keys: ["cafe"],
        weekly_hours: %{
          "0" => %{weekday: "1", opens_at: "08:00", closes_at: "18:00"}
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#place-profile-revision", "1")
    assert has_element?(view, "#profile_public_email[value='novo@perfil.example']")
    assert has_element?(view, "#profile_public_phone[value='+5588999990101']")

    assert {:ok, %{profile: %{revision: 1, categories: [%{key: "cafe"}]}}} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)
  end

  test "rejects a stale profile editor and reloads the winning revision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    category = Factory.insert(:place_category, key: "cafe", name: "Cafe")

    assert {:ok, _profile} =
             Directory.publish_place_profile(admin_scope, fixture.ids.place, %{
               contact: %{email: "original@perfil.example", phone: "+5588999990101"},
               category_keys: [category.key],
               weekly_hours: [%{weekday: 1, opens_at: "09:00", closes_at: "18:00"}],
               special_hours: [],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "place-live-profile-original"
             })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    old_key = input_value(view, "#profile_idempotency_key")

    assert {:ok, %{"profile" => %{"revision" => 2}}} =
             Directory.publish_place_profile(admin_scope, fixture.ids.place, %{
               contact: %{email: "vencedor@perfil.example", phone: "+5588999990202"},
               category_keys: [category.key],
               weekly_hours: [%{weekday: 2, opens_at: "10:00", closes_at: "19:00"}],
               special_hours: [],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-live-profile-winner"
             })

    view
    |> form("#place-profile-form", profile: %{public_email: "perdedor@perfil.example"})
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-profile-revision", "2")
    assert has_element?(view, "#profile_public_email[value='vencedor@perfil.example']")
    refute input_value(view, "#profile_idempotency_key") == old_key

    assert {:ok, %{profile: %{revision: 2, public_email: "vencedor@perfil.example"}}} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)
  end

  test "rejects profile writes after the browser session is revoked", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    Factory.insert(:place_category, key: "cafe", name: "Cafe")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#place-profile-form",
      profile: %{
        public_email: "bloqueado@perfil.example",
        public_phone: "+5588999990101",
        category_keys: ["cafe"]
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM polo_place_profiles WHERE polo_place_id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "handles malformed and unavailable profile events without terminating the LiveView", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_submit(view, "save_profile", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-profile-form")

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{action: "suspend", reason: "Bloqueio temporário do perfil"}
    )
    |> render_submit()

    assert has_element?(view, "#place-profile-editor-unavailable")
    refute has_element?(view, "#place-profile-form")

    render_submit(view, "save_profile", %{"profile" => %{}})
    render_change(view, "validate_profile", %{"profile" => %{}})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-profile-editor-unavailable")
  end

  test "renders an invited participation without lifecycle controls", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "UPDATE polo_places SET status = 'invited' WHERE id = $1",
               [fixture.ids.polo_place]
             )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#place-detail-status[data-status='invited']")
    assert has_element?(view, "#place-lifecycle-unavailable")
    refute has_element?(view, "#place-lifecycle-form")
  end

  test "selects the first authorized polo when the detail URL omits the polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}")

    assert has_element?(view, "#place-detail")
    assert has_element?(view, "#polo-switcher option[value='#{fixture.polo_slug}'][selected]")
  end

  test "navigates back to the inventory when the polo switcher changes", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_redirect(view, "/admin/places?polo=#{fixture.polo_slug}")
  end

  test "rejects a malformed polo switcher event without terminating the detail", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='active']")
  end

  test "an admin suspends the participation and sees the reloaded revision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "suspend",
        reason: "Pausa operacional confirmada no painel"
      }
    )
    |> render_submit()

    assert has_element?(view, "#place-detail-status[data-status='suspended']")
    assert has_element?(view, "#place-detail-revision", "2")
    assert has_element?(view, "#lifecycle_action option[value='reactivate']")

    assert {:ok, %{status: "suspended", revision: 2}} =
             Clubeira.Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)
  end

  test "rejects a stale lifecycle form and reloads the winning state", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert {:ok, %{"status" => "suspended", "revision" => 2}} =
             Directory.transition_place_participation(admin_scope, fixture.ids.place, %{
               action: "suspend",
               reason: "Suspensão decidida em outra sessão administrativa",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-detail-stale-winner"
             })

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "retire",
        reason: "Tentativa baseada em uma revisão antiga",
        confirm_retire: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='suspended']")
    assert has_element?(view, "#place-detail-revision", "2")
    assert has_element?(view, "#lifecycle_action option[value='reactivate']")

    assert {:ok, %{status: "suspended", revision: 2}} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)
  end

  test "reloads the winning state after an idempotency conflict", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    idempotency_key = input_value(view, "#lifecycle_idempotency_key")

    assert {:ok, %{"status" => "suspended", "revision" => 2}} =
             Directory.transition_place_participation(admin_scope, fixture.ids.place, %{
               action: "suspend",
               reason: "A outra sessão venceu esta operação",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: idempotency_key
             })

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "retire",
        reason: "Payload diferente para a chave já utilizada",
        confirm_retire: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='suspended']")
    assert has_element?(view, "#place-detail-revision", "2")
    assert has_element?(view, "#lifecycle_action option[value='reactivate']")
    refute input_value(view, "#lifecycle_idempotency_key") == idempotency_key
  end

  test "requires explicit confirmation before permanently retiring a participation", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "retire",
        reason: "Encerramento definitivo da participação",
        confirm_retire: "false"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='active']")
    assert has_element?(view, "#place-detail-revision", "1")

    assert {:ok, %{status: "active", revision: 1}} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "retire",
        reason: "Encerramento definitivo da participação",
        confirm_retire: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#place-detail-status[data-status='retired']")
    assert has_element?(view, "#place-detail-revision", "2")
    assert has_element?(view, "#place-lifecycle-unavailable")
    refute has_element?(view, "#place-lifecycle-form")
  end

  test "renders domain validation errors without changing the participation", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{action: "suspend", reason: "x"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-lifecycle-reason-field p")
    assert has_element?(view, "#place-detail-status[data-status='active']")
    assert has_element?(view, "#place-detail-revision", "1")

    assert {:ok, %{status: "active", revision: 1}} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)
  end

  test "reloads the current state after a lifecycle action invalid for that state", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_submit(view, "transition_place", %{
      "lifecycle" => %{
        "action" => "reactivate",
        "reason" => "Participação já está ativa",
        "idempotency_key" => "place-detail-invalid-active-reactivation"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='active']")
    assert has_element?(view, "#place-detail-revision", "1")
  end

  test "does not reveal a place through another authorized polo", %{conn: conn} do
    first_fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(first_fixture, role_key: "admin")

    second_fixture =
      RedemptionsFixtures.create!(user_id: admin_scope.actor_user_id, insert_user: false)

    ReviewsFixtures.grant_moderator!(second_fixture,
      role_key: "admin",
      user_id: admin_scope.actor_user_id,
      insert_user: false
    )

    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/places?polo=#{second_fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               conn,
               "/admin/places/#{first_fixture.ids.polo_place}?polo=#{second_fixture.polo_slug}"
             )
  end

  test "canonicalizes a tampered polo before loading a place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/places?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/places/#{fixture.ids.polo_place}?polo=not-authorized")
  end

  test "redirects an actor without partner-management capability", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")
  end

  test "reauthorizes a lifecycle command after the membership is revoked", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.ids.polo), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "suspend",
        reason: "Esta ação não deve sobreviver à revogação"
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")

    assert {:error, :partner_admin_required} =
             Directory.get_backoffice_place(admin_scope, fixture.ids.polo_place)

    assert %{rows: [["active", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status, revision FROM polo_places WHERE id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "rejects a lifecycle event after the browser session is revoked", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#place-lifecycle-form",
      lifecycle: %{
        action: "suspend",
        reason: "A sessão revogada não pode escrever"
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert %{rows: [["active", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status, revision FROM polo_places WHERE id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "handles malformed lifecycle events without terminating the LiveView", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_submit(view, "transition_place", %{})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='active']")
    assert has_element?(view, "#place-detail-revision", "1")
  end

  test "binds lifecycle concurrency fields to the participation rendered by the server", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    render_submit(view, "transition_place", %{
      "lifecycle" => %{
        "action" => "suspend",
        "reason" => "Campos de concorrência adulterados pelo cliente",
        "expected_polo_place_id" => Ecto.UUID.generate(),
        "expected_revision" => "999",
        "idempotency_key" => "place-detail-server-bound-target"
      }
    })

    assert has_element?(view, "#place-detail-status[data-status='suspended']")
    assert has_element?(view, "#place-detail-revision", "2")
  end

  test "does not accept a lifecycle event from a historical participation detail", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    assert {:ok, %{"status" => "retired", "revision" => 2}} =
             Directory.transition_place_participation(admin_scope, fixture.ids.place, %{
               action: "retire",
               reason: "Primeira participação encerrada para criar histórico",
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 1,
               idempotency_key: "place-detail-retire-first-generation"
             })

    replacement_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               INSERT INTO polo_places (
                 id,
                 city_id,
                 polo_id,
                 place_id,
                 participation_during,
                 status,
                 revision
               )
               VALUES (
                 $1,
                 $2,
                 $3,
                 $4,
                 tstzrange(statement_timestamp(), statement_timestamp() + interval '1 day', '[)'),
                 'active',
                 1
               )
               """,
               [replacement_id, fixture.ids.city, fixture.ids.polo, fixture.ids.place]
             )

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}")

    refute has_element?(view, "#place-lifecycle-form")

    render_submit(view, "transition_place", %{
      "lifecycle" => %{
        "action" => "suspend",
        "reason" => "Tela histórica não pode atingir a participação atual",
        "expected_polo_place_id" => replacement_id,
        "expected_revision" => "1",
        "idempotency_key" => "place-detail-historical-target-tampering"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#place-detail-status[data-status='retired']")

    assert %{rows: [["retired", 2], ["active", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, revision
               FROM polo_places
               WHERE id IN ($1, $2)
               ORDER BY inserted_at, id
               """,
               [fixture.ids.polo_place, replacement_id]
             )
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp input_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp insert_profile!(fixture) do
    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               INSERT INTO polo_place_profiles (
                 id,
                 polo_id,
                 polo_place_id,
                 public_email,
                 public_phone,
                 revision
               )
               VALUES ($1, $2, $3, 'operacao@example.test', '+5511999990000', 1)
               """,
               [
                 Ecto.UUID.generate(version: 7, precision: :monotonic),
                 fixture.ids.polo,
                 fixture.ids.polo_place
               ]
             )
  end
end
