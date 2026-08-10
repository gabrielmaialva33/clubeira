defmodule Clubeira.E2E.BackofficeOperationsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-operacoes-e2e"

  setup do
    server =
      start_supervised!({
        Bandit,
        plug: ClubeiraWeb.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [num_acceptors: 2]
      })

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  test "admin inspects and requeues a dead letter through the real HTTP stack", %{
    base_url: base_url
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin = Repo.get!(User, admin_scope.actor_user_id)
    assert {:ok, _credential} = Accounts.set_password(admin, @password)
    message_id = emit_dead_letter!(fixture)

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"access_token" => admin_token}}
           } =
             Req.post!("#{base_url}/api/v1/auth/sessions",
               json: %{"email" => admin.email, "password" => @password},
               retry: false
             )

    headers = [{"authorization", "Bearer #{admin_token}"}]

    operations_url =
      "#{base_url}/api/v1/polos/#{fixture.polo_slug}/backoffice"

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => ^message_id,
                   "status" => "dead_letter",
                   "attempt_count" => 3,
                   "has_error" => true
                 } = message
               ]
             }
           } =
             Req.get!("#{operations_url}/outbox-messages?status=dead_letter",
               headers: headers,
               retry: false
             )

    for private_field <- ~w(payload last_error locked_by message_key metadata) do
      refute Map.has_key?(message, private_field)
    end

    retry_request = [
      headers: [{"idempotency-key", "operations-e2e-retry-1"} | headers],
      json: %{},
      retry: false
    ]

    retry_url = "#{operations_url}/outbox-messages/#{message_id}/retries"

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "id" => ^message_id,
                 "status" => "pending",
                 "attempt_count" => 0
               }
             }
           } = first_retry = Req.post!(retry_url, retry_request)

    second_retry = Req.post!(retry_url, retry_request)
    assert second_retry.status == first_retry.status
    assert second_retry.body == first_retry.body

    audit_query =
      URI.encode_query(%{
        "action" => "outbox.message_requeued",
        "resource_type" => "outbox_message"
      })

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "actor_user_id" => actor_user_id,
                   "action" => "outbox.message_requeued",
                   "resource_id" => ^message_id
                 } = audit_event
               ],
               "meta" => %{"count" => 1}
             }
           } =
             Req.get!("#{operations_url}/audit-events?#{audit_query}",
               headers: headers,
               retry: false
             )

    assert actor_user_id == admin_scope.actor_user_id
    refute Map.has_key?(audit_event, "metadata")
  end

  test "web and app clients bootstrap public and staff navigation over real HTTP", %{
    base_url: base_url
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin = Repo.get!(User, admin_scope.actor_user_id)
    assert {:ok, _credential} = Accounts.set_password(admin, @password)

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => polo_id,
                   "slug" => polo_slug,
                   "city" => %{"country_code" => "BR"}
                 }
               ]
             }
           } = Req.get!("#{base_url}/api/v1/polos", retry: false)

    assert polo_id == fixture.ids.polo
    assert polo_slug == fixture.polo_slug

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"access_token" => admin_token}}
           } =
             Req.post!("#{base_url}/api/v1/auth/sessions",
               json: %{"email" => admin.email, "password" => @password},
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "platform" => %{"roles" => [], "capabilities" => []},
                 "polos" => [
                   %{
                     "id" => ^polo_id,
                     "slug" => ^polo_slug,
                     "roles" => ["admin"],
                     "capabilities" => capabilities
                   }
                 ]
               }
             }
           } =
             Req.get!("#{base_url}/api/v1/me/access",
               headers: [{"authorization", "Bearer #{admin_token}"}],
               retry: false
             )

    assert "manage_operations" in capabilities
    assert "manage_partners" in capabilities
  end

  defp emit_dead_letter!(fixture) do
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
            message_key: "operations-e2e",
            payload: %{"private_reference" => "must-not-leak"},
            occurred_at: now
          })

        message = Repo.get_by!(OutboxMessage, domain_event_id: event.id)
        {:ok, message.id}
      end)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE outbox_messages
      SET status = 'dead_letter',
          attempt_count = 3,
          last_error = 'private-error-must-not-leak'
      WHERE id = $1
      """,
      [message_id]
    )

    message_id
  end
end
