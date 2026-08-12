defmodule ClubeiraWeb.Backoffice.ValidationPointsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-a-validacao-web"

  test "lists only the selected polo validation points", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#validation-points-page")
    assert has_element?(view, "#validation-point-#{fixture.ids.validation_point}")
    refute has_element?(view, "#validation-point-#{other_polo.ids.validation_point}")
    assert has_element?(view, "#backoffice-nav-validation[aria-current='page']")
  end

  test "provisions a point and reveals its generated secret only as response material", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    name = "Totem #{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    view
    |> form("#validation-place-form", place: %{id: fixture.ids.place})
    |> render_change()

    view
    |> form("#validation-point-provision-form",
      validation_point: %{
        name: name,
        expires_at: DateTime.to_iso8601(DateTime.add(fixture.now, 86_400))
      }
    )
    |> render_submit()

    assert has_element?(view, "#validation-secret-reveal")

    assert has_element?(
             view,
             "#validation-secret-value[data-secret-format='base64url-32'][data-secret-length='43']"
           )

    assert {:ok, %{validation_points: points}} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})

    assert Enum.any?(points, &(&1.name == name and &1.credential.version == 1))
  end

  test "suspends a point and rotates its current credential", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    point_id = fixture.ids.validation_point
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    view
    |> form("#validation-point-lifecycle-form-#{point_id}",
      lifecycle: %{action: "suspend", reason: "Manutenção programada do caixa."}
    )
    |> render_submit()

    assert has_element?(view, "#validation-point-#{point_id} [data-status='suspended']")

    view
    |> form("#validation-credential-rotation-form-#{credential_id}",
      rotation: %{expires_at: DateTime.to_iso8601(DateTime.add(fixture.now, 172_800))}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#validation-secret-value[data-secret-format='base64url-32'][data-secret-length='43']"
           )

    assert {:ok, %{validation_points: [%{credential: %{version: 2}}]}} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "revokes the current credential and removes credential actions", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    view
    |> form("#validation-credential-revocation-form-#{credential_id}")
    |> render_submit()

    assert has_element?(view, "#flash-info")
    refute has_element?(view, "#validation-credential-revocation-form-#{credential_id}")
    refute has_element?(view, "#validation-credential-rotation-form-#{credential_id}")

    assert {:ok, %{validation_points: [%{credential: %{id: ^credential_id, status: "revoked"}}]}} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "rejects point and credential actions outside the rendered inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    point_id = fixture.ids.validation_point
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(
        "/admin/validation-points?polo=#{fixture.polo_slug}&place_id=#{fixture.ids.other_place}"
      )

    refute has_element?(view, "#validation-point-#{point_id}")

    render_hook(view, "transition_validation_point", %{
      "point_id" => point_id,
      "lifecycle" => %{
        "action" => "suspend",
        "reason" => "Evento forjado fora do inventário.",
        "idempotency_key" => "forged-validation-lifecycle"
      }
    })

    render_hook(view, "rotate_validation_credential", %{
      "credential_id" => credential_id,
      "rotation" => %{
        "expires_at" => DateTime.to_iso8601(DateTime.add(fixture.now, 172_800)),
        "idempotency_key" => "forged-validation-rotation"
      }
    })

    render_hook(view, "revoke_validation_credential", %{
      "credential_id" => credential_id,
      "revocation" => %{"idempotency_key" => "forged-validation-revocation"}
    })

    assert has_element?(view, "#flash-error")

    assert {:ok,
            %{
              validation_points: [
                %{id: ^point_id, status: "active", credential: %{version: 1, status: "active"}}
              ]
            }} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "refetches a credential that another operator already revoked", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    assert {:ok, _revocation} =
             Redemptions.revoke_validation_credential(admin_scope, credential_id, %{
               idempotency_key: "concurrent-credential-revocation-#{Ecto.UUID.generate()}"
             })

    view
    |> form("#validation-credential-revocation-form-#{credential_id}")
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#validation-credential-revocation-form-#{credential_id}")

    assert {:ok, %{validation_points: [%{credential: %{status: "revoked"}}]}} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "a revoked browser session cannot provision a validation point", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    name = "Sessão revogada #{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#validation-point-provision-form",
      validation_point: %{
        name: name,
        expires_at: DateTime.to_iso8601(DateTime.add(fixture.now, 86_400))
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{validation_points: points}} =
             Redemptions.list_validation_points(admin_scope, %{})

    refute Enum.any?(points, &(&1.name == name))
  end

  test "applies validation filters through canonical URL state while preserving page size", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}&limit=7")

    view
    |> form("#validation-point-filters",
      filters: %{status: "active", place_id: fixture.ids.place}
    )
    |> render_submit()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "polo" => fixture.polo_slug,
             "status" => "active",
             "place_id" => fixture.ids.place,
             "limit" => "7"
           }

    assert has_element?(view, "#validation-point-#{fixture.ids.validation_point}")
  end

  test "rejects malformed validation browser events without mutating inventory", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    for {event, payload} <- [
          {"change_polo", %{}},
          {"filter", %{"filters" => "invalid"}},
          {"select_validation_place", %{"place" => "invalid"}},
          {"provision_validation_point", %{"validation_point" => "invalid"}},
          {"transition_validation_point", %{"point_id" => fixture.ids.validation_point}},
          {"rotate_validation_credential",
           %{
             "credential_id" => fixture.ids.validation_credential
           }},
          {"revoke_validation_credential",
           %{
             "credential_id" => fixture.ids.validation_credential
           }}
        ] do
      render_hook(view, event, payload)
      assert has_element?(view, "#validation-points-page")
    end

    assert has_element?(view, "#flash-error")

    assert {:ok,
            %{
              validation_points: [
                %{status: "active", credential: %{version: 1, status: "active"}}
              ]
            }} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "canonicalizes invalid validation URL state instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/validation-points?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/validation-points?polo=#{fixture.polo_slug}&status=tampered")
  end

  test "redirects a review-only moderator away from validation management", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/validation-points?polo=#{fixture.polo_slug}")
  end

  test "a forged polo switch remains bound to the current authorized polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(view, "/admin/validation-points?polo=#{fixture.polo_slug}")
    assert has_element?(view, "#validation-point-#{fixture.ids.validation_point}")
  end

  test "keeps command forms and state when validation decisions are invalid", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    point_id = fixture.ids.validation_point
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    render_hook(view, "provision_validation_point", %{
      "validation_point" => %{
        "name" => "",
        "expires_at" => "invalid",
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#validation-point-provision-form")
    assert has_element?(view, "#flash-error")

    render_hook(view, "transition_validation_point", %{
      "point_id" => point_id,
      "lifecycle" => %{
        "action" => "invalid",
        "reason" => "",
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#validation-point-lifecycle-form-#{point_id}")
    assert has_element?(view, "#flash-error")

    render_hook(view, "rotate_validation_credential", %{
      "credential_id" => credential_id,
      "rotation" => %{"expires_at" => "invalid", "idempotency_key" => "short"}
    })

    assert has_element?(view, "#validation-credential-rotation-form-#{credential_id}")
    assert has_element?(view, "#flash-error")

    render_hook(view, "revoke_validation_credential", %{
      "credential_id" => credential_id,
      "revocation" => %{"idempotency_key" => "short"}
    })

    assert has_element?(view, "#validation-credential-revocation-form-#{credential_id}")
    assert has_element?(view, "#flash-error")

    assert {:ok,
            %{
              validation_points: [
                %{id: ^point_id, status: "active", credential: %{version: 1, status: "active"}}
              ]
            }} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})
  end

  test "requires an active place before provisioning", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    name = "Point without place #{System.unique_integer([:positive])}"

    TestDatabaseRole.as_owner(fn ->
      Repo.query!("UPDATE polo_places SET status = 'retired' WHERE id = $1", [
        Ecto.UUID.dump!(fixture.ids.polo_place)
      ])
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#validation-provisioning-without-place")
    refute has_element?(view, "#validation-point-provision-form")

    render_hook(view, "provision_validation_point", %{
      "validation_point" => %{
        "name" => name,
        "expires_at" => DateTime.to_iso8601(DateTime.add(fixture.now, 86_400)),
        "idempotency_key" => "validation-without-place-#{Ecto.UUID.generate()}"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{validation_points: points}} =
             Redemptions.list_validation_points(admin_scope, %{})

    refute Enum.any?(points, &(&1.name == name))
  end

  test "retires a point as a terminal state and removes its action forms", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(validation_credential_secret: random_credential())
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    point_id = fixture.ids.validation_point
    credential_id = fixture.ids.validation_credential

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/validation-points?polo=#{fixture.polo_slug}")

    view
    |> form("#validation-point-lifecycle-form-#{point_id}",
      lifecycle: %{action: "retire", reason: "Endpoint removido permanentemente."}
    )
    |> render_submit()

    assert has_element?(view, "#validation-point-#{point_id} [data-status='retired']")
    refute has_element?(view, "#validation-point-lifecycle-form-#{point_id}")
    refute has_element?(view, "#validation-credential-rotation-form-#{credential_id}")
    refute has_element?(view, "#validation-credential-revocation-form-#{credential_id}")

    assert {:ok,
            %{validation_points: [%{id: ^point_id, status: "retired", credential: credential}]}} =
             Redemptions.list_validation_points(admin_scope, %{"place_id" => fixture.ids.place})

    assert credential.status in ["expired", "revoked"]
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp random_credential do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
