defmodule Clubeira.PrivacyTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Audit.SystemEvent
  alias Clubeira.People
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Tenancy.ActorScope

  setup do
    user = insert(:user)
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))
    assert {:ok, profile} = People.put_self_profile(scope, %{"display_name" => "Titular LGPD"})

    purpose = PrivacyFixtures.consent_purpose!()

    %{notice: purpose, profile: profile, purpose: purpose, scope: scope, user: user}
  end

  test "PUT consent appends only real state transitions and returns the current safe state", %{
    notice: notice,
    profile: profile,
    purpose: purpose,
    scope: scope,
    user: user
  } do
    attributes = %{
      "state" => "granted",
      "legal_document_version_id" => notice.version_id
    }

    assert {:ok, granted} = Privacy.put_consent(scope, purpose.code, attributes)

    assert granted.processing_purpose == %{
             code: purpose.code,
             name: purpose.name,
             legal_basis: "consent",
             current_legal_document_version_id: notice.version_id
           }

    assert granted.state == "granted"
    assert granted.legal_document_version_id == notice.version_id
    assert granted.person_id == profile.id
    assert %DateTime{} = granted.occurred_at

    assert {:ok, ^granted} = Privacy.put_consent(scope, purpose.code, attributes)
    assert {:ok, [^granted]} = Privacy.list_consents(scope)

    assert {:ok, withdrawn} =
             Privacy.put_consent(scope, purpose.code, %{
               "state" => "withdrawn",
               "legal_document_version_id" => notice.version_id
             })

    assert withdrawn.state == "withdrawn"

    assert DateTime.after?(withdrawn.occurred_at, granted.occurred_at) or
             DateTime.compare(withdrawn.occurred_at, granted.occurred_at) == :eq

    assert {:ok, [^withdrawn]} = Privacy.list_consents(scope)

    assert {:ok, 2} =
             Repo.transact_as_actor(scope, fn repo ->
               {:ok, repo.aggregate("privacy_consent_events", :count)}
             end)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.resource_id == ^profile.id and
                   event.action in ["privacy.consent.granted", "privacy.consent.withdrawn"]
             ),
             :count
           ) == 2
  end

  test "submits one replayable data-subject request with an immutable initial timeline", %{
    profile: profile,
    scope: scope,
    user: user
  } do
    client_request_id = uuid7()
    attributes = %{"client_request_id" => client_request_id, "request_type" => "access"}

    assert {:ok, %{request: request, replayed?: false}} =
             Privacy.submit_request(scope, attributes)

    assert request.client_request_id == client_request_id
    assert request.person_id == profile.id
    assert request.request_type == "access"
    assert request.status == "received"
    assert request.completed_at == nil
    assert request.rejection_reason == nil
    assert [%{event_type: "received", payload: %{"status" => "received"}}] = request.events
    assert DateTime.diff(request.due_at, request.inserted_at, :second) == 15 * 24 * 60 * 60

    assert {:ok, %{request: ^request, replayed?: true}} =
             Privacy.submit_request(scope, attributes)

    assert {:error, :idempotency_conflict} =
             Privacy.submit_request(scope, %{
               "client_request_id" => client_request_id,
               "request_type" => "deletion"
             })

    assert {:ok, [^request]} = Privacy.list_requests(scope)

    assert {:ok, %{rows: [[1, 1]]}} =
             Repo.transact_as_actor(scope, fn repo ->
               result =
                 repo.query!("""
                 SELECT
                   (SELECT count(*) FROM privacy_requests),
                   (SELECT count(*) FROM privacy_request_events)
                 """)

               {:ok, result}
             end)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^user.id and
                   event.action == "privacy.request.received" and
                   event.resource_id == ^request.id
             ),
             :count
           ) == 1

    other_user = insert(:user)
    other_scope = ActorScope.new!(other_user.id, uuid7())
    assert {:error, :profile_required} = Privacy.list_requests(other_scope)
  end

  test "a current platform privacy officer processes the request through its audited lifecycle",
       %{
         scope: requester_scope,
         user: requester
       } do
    client_request_id = uuid7()

    assert {:ok, %{request: received, replayed?: false}} =
             Privacy.submit_request(requester_scope, %{
               "client_request_id" => client_request_id,
               "request_type" => "access"
             })

    officer = insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    officer_scope = ActorScope.new!(officer.id, uuid7())

    unauthorized = insert(:user)
    unauthorized_scope = ActorScope.new!(unauthorized.id, uuid7())

    assert {:error, :platform_privacy_officer_required} =
             Privacy.list_platform_requests(unauthorized_scope, %{})

    assert {:ok, %{requests: [listed], page: %{has_more: false}}} =
             Privacy.list_platform_requests(officer_scope, %{"status" => "received"})

    assert listed.id == received.id

    assert {:ok, %{request: processing, replayed?: false}} =
             Privacy.transition_request(officer_scope, received.id, %{
               "action" => "start_processing",
               "expected_status" => "received"
             })

    assert processing.status == "in_progress"
    assert Enum.map(processing.events, & &1.event_type) == ["received", "processing_started"]

    assert {:ok, %{request: ^processing, replayed?: true}} =
             Privacy.transition_request(officer_scope, received.id, %{
               "action" => "start_processing",
               "expected_status" => "received"
             })

    assert {:ok, %{request: completed, replayed?: false}} =
             Privacy.transition_request(officer_scope, received.id, %{
               "action" => "complete",
               "expected_status" => "in_progress"
             })

    assert completed.status == "completed"
    assert %DateTime{} = completed.completed_at

    assert {:ok, [requester_view]} = Privacy.list_requests(requester_scope)
    assert requester_view == completed

    assert Repo.exists?(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^officer.id and
                   event.resource_id == ^received.id and
                   event.action == "privacy.request.completed"
             )
           )

    refute Repo.exists?(
             from(event in SystemEvent,
               where:
                 event.actor_user_id == ^requester.id and
                   event.resource_id == ^received.id and
                   event.action == "privacy.request.completed"
             )
           )
  end

  test "platform request pagination and every terminal transition remain deterministic", %{
    scope: requester_scope
  } do
    officer = insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    officer_scope = ActorScope.new!(officer.id, uuid7())

    requests =
      Enum.map(1..3, fn _index ->
        assert {:ok, %{request: request}} =
                 Privacy.submit_request(requester_scope, %{
                   "client_request_id" => uuid7(),
                   "request_type" => "access"
                 })

        request
      end)

    assert {:ok, %{requests: [_first], page: %{has_more: true, next_cursor: cursor}}} =
             Privacy.list_platform_requests(officer_scope, %{"limit" => "1"})

    assert is_binary(cursor)

    assert {:ok, %{requests: [_second], page: %{has_more: true}}} =
             Privacy.list_platform_requests(officer_scope, %{
               "limit" => "1",
               "after" => cursor
             })

    [identity_request, rejected_request, cancelled_request] = requests

    assert {:ok, %{request: identity}} =
             Privacy.transition_request(officer_scope, identity_request.id, %{
               "action" => "start_identity_verification",
               "expected_status" => "received"
             })

    assert identity.status == "identity_verification"

    assert {:ok, %{request: processing}} =
             Privacy.transition_request(officer_scope, identity_request.id, %{
               "action" => "start_processing",
               "expected_status" => "identity_verification"
             })

    assert {:ok, %{request: partial}} =
             Privacy.transition_request(officer_scope, identity_request.id, %{
               "action" => "partially_complete",
               "expected_status" => processing.status
             })

    assert partial.status == "partially_completed"

    assert {:ok, %{request: rejected}} =
             Privacy.transition_request(officer_scope, rejected_request.id, %{
               "action" => "reject",
               "expected_status" => "received",
               "rejection_reason" => "Identidade não pôde ser comprovada."
             })

    assert rejected.status == "rejected"
    assert rejected.rejection_reason == "Identidade não pôde ser comprovada."

    assert {:ok, %{request: cancelled}} =
             Privacy.transition_request(officer_scope, cancelled_request.id, %{
               "action" => "cancel",
               "expected_status" => "received"
             })

    assert cancelled.status == "cancelled"

    assert {:error, :invalid_privacy_request_transition} =
             Privacy.transition_request(officer_scope, cancelled_request.id, %{
               "action" => "start_processing",
               "expected_status" => "cancelled"
             })
  end

  test "processing purposes enforce their legal evidence at the platform boundary", %{
    notice: notice
  } do
    officer = insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    officer_scope = ActorScope.new!(officer.id, uuid7())

    assert {:error, :consent_notice_unavailable} =
             Privacy.put_processing_purpose(officer_scope, "research-consent", %{
               "name" => "Pesquisa com consentimento",
               "legal_basis" => "consent",
               "status" => "active"
             })

    assert {:error, :legal_document_unavailable} =
             Privacy.put_processing_purpose(officer_scope, "contract-invalid-document", %{
               "name" => "Execução contratual",
               "legal_basis" => "contract",
               "legal_document_version_id" => uuid7(),
               "status" => "active"
             })

    assert {:ok, purpose} =
             Privacy.put_processing_purpose(officer_scope, "contract-operations", %{
               "name" => "Operações do contrato",
               "legal_basis" => "contract",
               "status" => "active"
             })

    assert purpose.legal_document_version_id == nil

    assert {:ok, consent} =
             Privacy.put_processing_purpose(officer_scope, "research-consent", %{
               "name" => "Pesquisa com consentimento",
               "legal_basis" => "consent",
               "legal_document_version_id" => notice.version_id,
               "status" => "active"
             })

    assert consent.legal_document_version_id == notice.version_id
  end

  test "public privacy functions fail closed on malformed scopes and inputs", %{scope: scope} do
    assert {:error, :invalid_actor_scope} = Privacy.put_consent(nil, "purpose", %{})
    assert {:error, :invalid_actor_scope} = Privacy.list_consents(nil)
    assert {:error, :invalid_actor_scope} = Privacy.submit_request(nil, %{})
    assert {:error, :invalid_actor_scope} = Privacy.list_requests(nil)
    assert {:error, :invalid_actor_scope} = Privacy.list_platform_requests(nil, %{})
    assert {:error, :invalid_actor_scope} = Privacy.transition_request(nil, uuid7(), %{})
    assert {:error, :invalid_actor_scope} = Privacy.list_processing_purposes(nil)
    assert {:error, :invalid_actor_scope} = Privacy.put_processing_purpose(nil, "purpose", %{})

    assert {:error, %Ecto.Changeset{}} = Privacy.put_consent(scope, "purpose", :invalid)
    assert {:error, %Ecto.Changeset{}} = Privacy.submit_request(scope, :invalid)
    assert {:error, :invalid_pagination} = Privacy.list_platform_requests(scope, :invalid)

    assert {:error, %Ecto.Changeset{}} =
             Privacy.transition_request(scope, uuid7(), :invalid)

    assert {:error, :invalid_processing_purpose} =
             Privacy.put_processing_purpose(scope, "INVALID CODE", %{})

    assert {:error, :invalid_pagination} =
             Privacy.list_platform_requests(scope, %{"limit" => "0"})

    assert {:error, :invalid_pagination} =
             Privacy.list_platform_requests(scope, %{"after" => String.duplicate("a", 129)})

    assert {:error, :invalid_privacy_request_status} =
             Privacy.list_platform_requests(scope, %{"status" => "unknown"})

    assert {:error, :privacy_request_not_found} =
             Privacy.transition_request(scope, "not-a-uuid", %{
               "action" => "cancel",
               "expected_status" => "received"
             })
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
