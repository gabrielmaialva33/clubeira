defmodule ClubeiraWeb.Backoffice.OperationsOutboxLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Operations
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-a-outbox-web"

  test "lists only the selected polo dead letters for an operations admin", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "private-reference")
    other_message_id = emit_dead_letter!(other_polo, "other-private-reference")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    assert has_element?(view, "#operations-outbox-page")
    assert has_element?(view, "#outbox-messages #outbox-message-#{message_id}")
    refute has_element?(view, "#outbox-messages #outbox-message-#{other_message_id}")
    assert has_element?(view, "#backoffice-nav-operations[aria-current='page']")
  end

  test "requeues a dead letter and removes it from the failure queue", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "retry-private-reference")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    view
    |> form("#outbox-retry-form-#{message_id}")
    |> render_submit()

    refute has_element?(view, "#outbox-message-#{message_id}")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{messages: [%{id: ^message_id, status: "pending", has_error: false}]}} =
             Operations.list_backoffice_outbox_messages(admin_scope, %{
               "status" => "pending"
             })
  end

  test "rejects a retry event for a message outside the rendered page", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "off-page-private-reference")

    assert {:ok, %{messages: [message]}} =
             Operations.list_backoffice_outbox_messages(admin_scope, %{
               "status" => "dead_letter"
             })

    assert message.id == message_id
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(
        "/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter&after=#{cursor(message.recorded_at, message.id)}"
      )

    refute has_element?(view, "#outbox-message-#{message.id}")

    render_hook(view, "retry_outbox_message", %{
      "message_id" => message.id,
      "retry" => %{"idempotency_key" => "forged-outbox-retry"}
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{messages: [%{id: ^message_id, status: "dead_letter"}]}} =
             Operations.list_backoffice_outbox_messages(admin_scope, %{
               "status" => "dead_letter"
             })
  end

  test "refetches a dead letter that another operator already requeued", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "concurrent-retry-private-reference")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    assert {:ok, %{"id" => ^message_id, "status" => "pending"}} =
             Operations.retry_outbox_message(admin_scope, message_id, %{
               idempotency_key: "concurrent-outbox-retry-#{Ecto.UUID.generate()}"
             })

    view
    |> form("#outbox-retry-form-#{message_id}")
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#outbox-message-#{message_id}")
  end

  test "keeps a dead letter unchanged for an invalid retry command", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "invalid-retry-private-reference")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    render_hook(view, "retry_outbox_message", %{
      "message_id" => message_id,
      "retry" => %{"idempotency_key" => "short"}
    })

    assert has_element?(view, "#outbox-retry-form-#{message_id}")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{messages: [%{id: ^message_id, status: "dead_letter"}]}} =
             Operations.list_backoffice_outbox_messages(admin_scope, %{
               "status" => "dead_letter"
             })
  end

  test "a revoked browser session cannot retry an outbox message", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "revoked-session-private-reference")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#outbox-retry-form-#{message_id}")
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{messages: [%{id: ^message_id, status: "dead_letter"}]}} =
             Operations.list_backoffice_outbox_messages(admin_scope, %{
               "status" => "dead_letter"
             })
  end

  test "redirects an operator without the operations capability", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/operations/outbox?polo=#{fixture.polo_slug}")
  end

  test "invalid URL state redirects safely instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/operations/outbox?polo=#{fixture.polo_slug}&after=invalid")
  end

  test "keeps the current polo for unknown switches and rejects malformed events", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "outbox-browser-boundary")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(
      view,
      "/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter"
    )

    assert has_element?(view, "#outbox-message-#{message_id}")

    render_change(view, "change_polo", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "retry_outbox_message", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#outbox-message-#{message_id}")
  end

  test "reauthorizes the operations role before retrying", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture, "revoked-role-outbox-retry")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}&status=dead_letter")

    revoke_membership!(fixture.ids.polo, admin_scope.actor_user_id)

    view
    |> form("#outbox-retry-form-#{message_id}")
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_slug}")
  end

  test "renders every operational status and the English timestamp format", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")

    pending_id = emit_dead_letter!(fixture, "pending-status")
    publishing_id = emit_dead_letter!(fixture, "publishing-status")
    published_id = emit_dead_letter!(fixture, "published-status")

    set_message_status!(fixture, pending_id, "pending")
    set_message_status!(fixture, publishing_id, "publishing")
    set_message_status!(fixture, published_id, "published")

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/operations/outbox?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#outbox-message-#{pending_id}", "Pending")
    assert has_element?(view, "#outbox-message-#{publishing_id}", "Publishing")
    assert has_element?(view, "#outbox-message-#{published_id}", "Published")

    assert has_element?(
             view,
             "#outbox-message-#{published_id} dd",
             ~r/\d{4}-\d{2}-\d{2}/
           )
  end

  defp emit_dead_letter!(fixture, private_reference) do
    {:ok, message_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        now = DateTime.utc_now(:microsecond)

        event =
          Events.emit!(repo, %{
            polo_id: fixture.ids.polo,
            aggregate_type: "test_operation",
            aggregate_id: Ecto.UUID.generate(version: 7),
            aggregate_version: 1,
            event_type: "test.operations.failed",
            topic: "tests.operations",
            message_key: private_reference,
            payload: %{"private_reference" => private_reference},
            metadata: %{"private_reference" => private_reference},
            occurred_at: now
          })

        message = repo.get_by!(OutboxMessage, domain_event_id: event.id)
        {:ok, message.id}
      end)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE outbox_messages
      SET status = 'dead_letter',
          attempt_count = 3,
          locked_at = NULL,
          locked_by = NULL,
          last_error = 'private-delivery-error'
      WHERE id = $1
      """,
      [message_id]
    )

    message_id
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp revoke_membership!(polo_id, user_id) do
    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(polo_id), Ecto.UUID.dump!(user_id)]
      )
    end)
  end

  defp set_message_status!(fixture, message_id, status) do
    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE outbox_messages SET status = $2 WHERE id = $1",
      [message_id, status]
    )
  end

  defp cursor(recorded_at, id) do
    <<DateTime.to_unix(recorded_at, :microsecond)::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
