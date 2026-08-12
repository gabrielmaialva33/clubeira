defmodule ClubeiraWeb.Backoffice.OperationsAuditLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-a-auditoria-web"

  test "lists only the selected polo audit events for an operations admin", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    audit_id = record_audit!(fixture, "private-explanation")
    other_audit_id = record_audit!(other_polo, "other-private-explanation")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/audit?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#operations-audit-page")
    assert has_element?(view, "#audit-events #audit-event-#{audit_id}")
    refute has_element?(view, "#audit-events #audit-event-#{other_audit_id}")
    refute has_element?(view, "#operations-audit-page", "private-explanation")
    refute has_element?(view, "#operations-audit-page", "other-private-explanation")
    assert has_element?(view, "#backoffice-nav-operations[aria-current='page']")
  end

  test "invalid audit URL state redirects safely instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/operations/audit?polo=#{fixture.polo_slug}&after=invalid")
  end

  test "a revoked polo membership cannot refresh the audit trail", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/audit?polo=#{fixture.polo_slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.ids.polo), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    render_hook(view, "change_polo", %{"context" => %{"polo" => fixture.polo_slug}})

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")
  end

  defp record_audit!(fixture, private_explanation) do
    {:ok, audit_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        event =
          Audit.record_tenant!(repo, fixture.scope, %{
            action: "test.operation.completed",
            resource_type: "test_operation",
            resource_id: Ecto.UUID.generate(version: 7),
            metadata: %{"private_explanation" => private_explanation},
            occurred_at: DateTime.utc_now(:microsecond)
          })

        {:ok, event.id}
      end)

    audit_id
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
