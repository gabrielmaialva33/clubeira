defmodule Clubeira.Privacy do
  @moduledoc """
  Consent timelines and data-subject requests owned by an authenticated actor.

  Consent is an idempotent desired-state PUT. Repeating the current state and
  legal version does not create duplicate immutable evidence.
  """

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.People.Person
  alias Clubeira.People.UserPersonLink
  alias Clubeira.Platform.Authorization
  alias Clubeira.Privacy.ConsentCommand
  alias Clubeira.Privacy.ConsentEvent
  alias Clubeira.Privacy.ProcessingPurpose
  alias Clubeira.Privacy.Request, as: PrivacyRequest
  alias Clubeira.Privacy.RequestEvent
  alias Clubeira.Privacy.RequestSubmission
  alias Clubeira.Privacy.RequestTransition
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @default_page_limit 20
  @maximum_page_limit 100
  @request_statuses ~w(
    received
    identity_verification
    in_progress
    completed
    partially_completed
    rejected
    cancelled
  )

  @purpose_code_pattern ~r/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/

  @type consent_state :: %{
          processing_purpose: map(),
          state: String.t(),
          legal_document_version_id: Ecto.UUID.t() | nil,
          person_id: Ecto.UUID.t(),
          occurred_at: DateTime.t() | nil
        }

  @spec put_consent(ActorScope.t(), String.t(), map()) ::
          {:ok, consent_state()} | {:error, atom() | Ecto.Changeset.t()}
  def put_consent(%ActorScope{} = scope, purpose_code, attributes)
      when is_binary(purpose_code) and is_map(attributes) do
    with {:ok, command} <- ConsentCommand.new(attributes) do
      Repo.transact_as_actor(
        scope,
        &put_consent_in_scope(&1, scope, purpose_code, command)
      )
    end
  end

  def put_consent(%ActorScope{}, _purpose_code, attributes),
    do: ConsentCommand.new(attributes)

  def put_consent(_scope, _purpose_code, _attributes), do: {:error, :invalid_actor_scope}

  @spec list_consents(ActorScope.t()) ::
          {:ok, [consent_state()]} | {:error, :profile_required | :invalid_actor_scope}
  def list_consents(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      with {:ok, person} <- fetch_self_person(repo, scope.actor_user_id) do
        purposes =
          repo.all(
            from(purpose in ProcessingPurpose,
              where: purpose.status == "active" and purpose.legal_basis == "consent",
              order_by: [asc: purpose.code]
            )
          )

        events = latest_events(repo, person.id)

        {:ok,
         Enum.map(purposes, fn purpose ->
           consent_view(purpose, person.id, Map.get(events, purpose.id))
         end)}
      end
    end)
  end

  def list_consents(_scope), do: {:error, :invalid_actor_scope}

  @spec submit_request(ActorScope.t(), map()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def submit_request(%ActorScope{} = scope, attributes) when is_map(attributes) do
    with {:ok, submission} <- RequestSubmission.new(attributes) do
      Repo.transact_as_actor(scope, &submit_request_in_scope(&1, scope, submission))
    end
  end

  def submit_request(%ActorScope{}, attributes), do: RequestSubmission.new(attributes)
  def submit_request(_scope, _attributes), do: {:error, :invalid_actor_scope}

  @spec list_requests(ActorScope.t()) ::
          {:ok, [map()]} | {:error, :profile_required | :invalid_actor_scope}
  def list_requests(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      with {:ok, _person} <- fetch_self_person(repo, scope.actor_user_id) do
        requests =
          repo.all(
            from(request in PrivacyRequest,
              where: request.requester_user_id == ^scope.actor_user_id,
              order_by: [desc: request.inserted_at, desc: request.id]
            )
          )

        {:ok, build_request_views(repo, requests)}
      end
    end)
  end

  def list_requests(_scope), do: {:error, :invalid_actor_scope}

  @spec list_platform_requests(ActorScope.t(), map()) ::
          {:ok, %{requests: [map()], page: map()}} | {:error, atom()}
  def list_platform_requests(%ActorScope{} = scope, params) when is_map(params) do
    with {:ok, filters} <- parse_platform_request_filters(params) do
      Repo.transact_as_actor(
        scope,
        &list_platform_requests_in_scope(&1, scope, filters)
      )
    end
  end

  def list_platform_requests(%ActorScope{}, _params), do: {:error, :invalid_pagination}
  def list_platform_requests(_scope, _params), do: {:error, :invalid_actor_scope}

  @spec transition_request(ActorScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def transition_request(%ActorScope{} = scope, request_id, attributes)
      when is_map(attributes) do
    with {:ok, request_id} <- cast_uuid(request_id),
         {:ok, transition} <- RequestTransition.new(attributes) do
      Repo.transact_as_actor(
        scope,
        &transition_request_in_scope(&1, scope, request_id, transition)
      )
    end
  end

  def transition_request(%ActorScope{}, _request_id, attributes),
    do: RequestTransition.new(attributes)

  def transition_request(_scope, _request_id, _attributes),
    do: {:error, :invalid_actor_scope}

  @spec list_processing_purposes(ActorScope.t()) ::
          {:ok, [map()]} | {:error, atom()}
  def list_processing_purposes(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      now = transaction_time(repo)

      with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now) do
        purposes =
          repo.all(
            from(purpose in ProcessingPurpose,
              order_by: [asc: purpose.code]
            )
          )

        {:ok, Enum.map(purposes, &processing_purpose_view/1)}
      end
    end)
  end

  def list_processing_purposes(_scope), do: {:error, :invalid_actor_scope}

  @spec put_processing_purpose(ActorScope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put_processing_purpose(%ActorScope{} = scope, code, attributes)
      when is_binary(code) and is_map(attributes) do
    with :ok <- validate_purpose_code(code) do
      Repo.transact_as_actor(
        scope,
        &put_processing_purpose_in_scope(&1, scope, code, attributes)
      )
    end
  end

  def put_processing_purpose(%ActorScope{}, _code, _attributes),
    do: {:error, :invalid_processing_purpose}

  def put_processing_purpose(_scope, _code, _attributes),
    do: {:error, :invalid_actor_scope}

  defp put_consent_in_scope(repo, scope, purpose_code, command) do
    now = transaction_time(repo)

    with {:ok, person} <- lock_self_person(repo, scope.actor_user_id),
         {:ok, purpose} <-
           fetch_consent_purpose(repo, purpose_code, command.legal_document_version_id) do
      put_consent_state(repo, scope, person, purpose, command, now)
    end
  end

  defp submit_request_in_scope(repo, scope, submission) do
    now = transaction_time(repo)

    with {:ok, person} <- lock_self_person(repo, scope.actor_user_id) do
      submit_request_for_person(repo, scope, person, submission, now)
    end
  end

  defp submit_request_for_person(repo, scope, person, submission, now) do
    request_hash = request_fingerprint(scope.actor_user_id, person.id, submission.request_type)

    case fetch_request(repo, scope.actor_user_id, submission.client_request_id) do
      %PrivacyRequest{} = request -> replay_request(repo, request, request_hash)
      nil -> insert_request(repo, scope, person, submission, request_hash, now)
    end
  end

  defp list_platform_requests_in_scope(repo, scope, filters) do
    now = transaction_time(repo)

    case Authorization.authorize(repo, scope, :manage_privacy, now) do
      :ok -> platform_request_page(repo, filters)
      {:error, _reason} = error -> error
    end
  end

  defp platform_request_page(repo, filters) do
    requests = fetch_platform_requests(repo, filters)
    {page_requests, overflow} = Enum.split(requests, filters.limit)
    has_more? = overflow != []

    {:ok,
     %{
       requests: build_request_views(repo, page_requests),
       page: %{
         limit: filters.limit,
         has_more: has_more?,
         next_cursor: next_request_cursor(page_requests, has_more?)
       }
     }}
  end

  defp transition_request_in_scope(repo, scope, request_id, transition) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now) do
      case lock_request(repo, request_id) do
        %PrivacyRequest{} = request ->
          apply_request_transition(repo, scope, request, transition, now)

        nil ->
          {:error, :privacy_request_not_found}
      end
    end
  end

  defp put_processing_purpose_in_scope(repo, scope, code, attributes) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now),
         :ok <- validate_purpose_legal_document(repo, attributes) do
      lock_processing_purpose_code!(repo, code)
      put_processing_purpose_record(repo, scope, code, attributes, now)
    end
  end

  defp put_consent_state(repo, scope, person, purpose, command, now) do
    current = latest_event(repo, person.id, purpose.id)

    if current_state?(current, command) do
      {:ok, consent_view(purpose, person.id, current)}
    else
      event =
        %{
          processing_purpose_id: purpose.id,
          legal_document_version_id: command.legal_document_version_id,
          person_id: person.id,
          user_id: scope.actor_user_id,
          event_type: command.state,
          evidence: %{"source" => "authenticated_api"}
        }
        |> ConsentEvent.create_changeset(now)
        |> repo.insert!()

      Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
        actor_user_id: scope.actor_user_id,
        action: "privacy.consent.#{command.state}",
        resource_type: "person",
        resource_id: person.id,
        metadata: %{"processing_purpose_id" => purpose.id},
        occurred_at: now
      })

      {:ok, consent_view(purpose, person.id, event)}
    end
  end

  defp put_processing_purpose_record(repo, scope, code, attributes, now) do
    purpose =
      repo.one(
        from(purpose in ProcessingPurpose,
          where: purpose.code == ^code,
          lock: "FOR UPDATE"
        )
      ) ||
        %ProcessingPurpose{
          code: code,
          inserted_at: now,
          updated_at: now
        }

    changeset = ProcessingPurpose.put_changeset(purpose, attributes, now)

    if changeset.valid? and changeset.changes == %{} do
      {:ok, processing_purpose_view(purpose)}
    else
      case repo.insert_or_update(changeset) do
        {:ok, saved} ->
          record_processing_purpose_change!(repo, scope, saved, now)
          {:ok, processing_purpose_view(saved)}

        {:error, %Ecto.Changeset{} = invalid} ->
          {:error, invalid}
      end
    end
  end

  defp record_processing_purpose_change!(repo, scope, purpose, now) do
    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: "privacy.processing_purpose.put",
      resource_type: "processing_purpose",
      resource_id: purpose.id,
      metadata: %{
        "code" => purpose.code,
        "legal_basis" => purpose.legal_basis,
        "status" => purpose.status
      },
      occurred_at: now
    })
  end

  defp validate_purpose_code(code) when byte_size(code) in 2..100 do
    if Regex.match?(@purpose_code_pattern, code),
      do: :ok,
      else: {:error, :invalid_processing_purpose}
  end

  defp validate_purpose_code(_code), do: {:error, :invalid_processing_purpose}

  defp validate_purpose_legal_document(repo, attributes) do
    legal_basis = Map.get(attributes, "legal_basis") || Map.get(attributes, :legal_basis)

    version_id =
      Map.get(attributes, "legal_document_version_id") ||
        Map.get(attributes, :legal_document_version_id)

    case {legal_basis, Ecto.UUID.cast(version_id)} do
      {"consent", {:ok, version_id}} -> consent_notice_available?(repo, version_id)
      {"consent", _invalid} -> {:error, :consent_notice_unavailable}
      {_other, {:ok, version_id}} -> legal_document_available?(repo, version_id)
      {_other, :error} when is_nil(version_id) -> :ok
      {_other, :error} -> {:error, :legal_document_unavailable}
    end
  end

  defp consent_notice_available?(repo, version_id) do
    query =
      from(version in DocumentVersion,
        join: document in Document,
        on: document.id == version.legal_document_id,
        where:
          version.id == ^version_id and document.status == "active" and
            document.audience == "consumer" and document.document_kind == "consent_notice" and
            fragment("? @> statement_timestamp()", version.effective_during)
      )

    if repo.exists?(query), do: :ok, else: {:error, :consent_notice_unavailable}
  end

  defp legal_document_available?(repo, version_id) do
    query =
      from(version in DocumentVersion,
        join: document in Document,
        on: document.id == version.legal_document_id,
        where:
          version.id == ^version_id and document.status == "active" and
            fragment("? @> statement_timestamp()", version.effective_during)
      )

    if repo.exists?(query), do: :ok, else: {:error, :legal_document_unavailable}
  end

  defp lock_processing_purpose_code!(repo, code) do
    repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["privacy.processing_purpose:" <> code]
    )

    :ok
  end

  defp processing_purpose_view(purpose) do
    %{
      id: purpose.id,
      code: purpose.code,
      name: purpose.name,
      legal_basis: purpose.legal_basis,
      legal_document_version_id: purpose.legal_document_version_id,
      status: purpose.status,
      inserted_at: purpose.inserted_at,
      updated_at: purpose.updated_at
    }
  end

  defp insert_request(repo, scope, person, submission, request_hash, now) do
    attributes = %{
      requester_user_id: scope.actor_user_id,
      person_id: person.id,
      client_request_id: submission.client_request_id,
      request_sha256: request_hash,
      request_type: submission.request_type,
      status: "received",
      due_at: DateTime.add(now, 15 * 24 * 60 * 60),
      inserted_at: now,
      updated_at: now
    }

    case attributes
         |> PrivacyRequest.create_changeset()
         |> repo.insert(mode: :savepoint) do
      {:ok, request} ->
        insert_received_event!(repo, scope, request, now)
        record_request_received!(repo, scope, request, now)
        {:ok, %{request: build_request_view(repo, request), replayed?: false}}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :client_request_id) do
          request =
            fetch_request(repo, scope.actor_user_id, submission.client_request_id) ||
              raise "privacy request uniqueness conflict without a visible request"

          replay_request(repo, request, request_hash)
        else
          {:error, changeset}
        end
    end
  end

  defp apply_request_transition(repo, scope, request, transition, now) do
    target = transition_target(transition.action)

    cond do
      replayed_transition?(request, target, transition) ->
        {:ok, %{request: build_request_view(repo, request), replayed?: true}}

      request.status != transition.expected_status ->
        {:error, :stale_privacy_request}

      not transition_allowed?(request.status, transition.action) ->
        {:error, :invalid_privacy_request_transition}

      true ->
        complete_request_transition(repo, scope, request, transition, target, now)
    end
  end

  defp complete_request_transition(repo, scope, request, transition, target, now) do
    terminal? = target in ~w(completed partially_completed rejected cancelled)
    rejection_reason = if target == "rejected", do: transition.rejection_reason

    updated =
      request
      |> Ecto.Changeset.change(%{
        status: target,
        completed_at: if(terminal?, do: now),
        rejection_reason: rejection_reason,
        updated_at: now
      })
      |> repo.update!()

    event_type = transition_event_type(transition.action)

    %{
      privacy_request_id: request.id,
      actor_user_id: scope.actor_user_id,
      event_type: event_type,
      payload: %{"status" => target}
    }
    |> RequestEvent.create_changeset(now)
    |> repo.insert!()

    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: "privacy.request.#{event_type}",
      resource_type: "privacy_request",
      resource_id: request.id,
      metadata: %{"status" => target},
      occurred_at: now
    })

    {:ok, %{request: build_request_view(repo, updated), replayed?: false}}
  end

  defp lock_request(repo, request_id) do
    repo.one(
      from(request in PrivacyRequest, where: request.id == ^request_id, lock: "FOR UPDATE")
    )
  end

  defp replayed_transition?(request, target, transition) do
    request.status == target and
      (target != "rejected" or request.rejection_reason == transition.rejection_reason)
  end

  defp transition_allowed?("received", action),
    do: action in ~w(start_identity_verification start_processing reject cancel)

  defp transition_allowed?("identity_verification", action),
    do: action in ~w(start_processing reject cancel)

  defp transition_allowed?("in_progress", action),
    do: action in ~w(complete partially_complete reject cancel)

  defp transition_allowed?(_status, _action), do: false

  defp transition_target("start_identity_verification"), do: "identity_verification"
  defp transition_target("start_processing"), do: "in_progress"
  defp transition_target("complete"), do: "completed"
  defp transition_target("partially_complete"), do: "partially_completed"
  defp transition_target("reject"), do: "rejected"
  defp transition_target("cancel"), do: "cancelled"

  defp transition_event_type("start_identity_verification"),
    do: "identity_verification_started"

  defp transition_event_type("start_processing"), do: "processing_started"
  defp transition_event_type("complete"), do: "completed"
  defp transition_event_type("partially_complete"), do: "partially_completed"
  defp transition_event_type("reject"), do: "rejected"
  defp transition_event_type("cancel"), do: "cancelled"

  defp replay_request(repo, request, request_hash) do
    if :crypto.hash_equals(request.request_sha256, request_hash) do
      {:ok, %{request: build_request_view(repo, request), replayed?: true}}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp insert_received_event!(repo, scope, request, now) do
    %{
      privacy_request_id: request.id,
      actor_user_id: scope.actor_user_id,
      event_type: "received",
      payload: %{"status" => "received"}
    }
    |> RequestEvent.create_changeset(now)
    |> repo.insert!()
  end

  defp record_request_received!(repo, scope, request, now) do
    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: "privacy.request.received",
      resource_type: "privacy_request",
      resource_id: request.id,
      metadata: %{"request_type" => request.request_type},
      occurred_at: now
    })
  end

  defp fetch_request(repo, actor_user_id, client_request_id) do
    repo.one(
      from(request in PrivacyRequest,
        where:
          request.requester_user_id == ^actor_user_id and
            request.client_request_id == ^client_request_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp build_request_views(_repo, []), do: []

  defp build_request_views(repo, requests) do
    request_ids = Enum.map(requests, & &1.id)

    events_by_request =
      repo.all(
        from(event in RequestEvent,
          where: event.privacy_request_id in ^request_ids,
          order_by: [asc: event.occurred_at, asc: event.id]
        )
      )
      |> Enum.group_by(& &1.privacy_request_id)

    Enum.map(requests, fn request ->
      request_view(request, Map.get(events_by_request, request.id, []))
    end)
  end

  defp build_request_view(repo, request) do
    events =
      repo.all(
        from(event in RequestEvent,
          where: event.privacy_request_id == ^request.id,
          order_by: [asc: event.occurred_at, asc: event.id]
        )
      )

    request_view(request, events)
  end

  defp request_view(request, events) do
    %{
      id: request.id,
      client_request_id: request.client_request_id,
      person_id: request.person_id,
      request_type: request.request_type,
      status: request.status,
      due_at: request.due_at,
      completed_at: request.completed_at,
      rejection_reason: request.rejection_reason,
      inserted_at: request.inserted_at,
      updated_at: request.updated_at,
      events: Enum.map(events, &request_event_view/1)
    }
  end

  defp request_event_view(event) do
    %{
      event_type: event.event_type,
      payload: event.payload,
      occurred_at: event.occurred_at
    }
  end

  defp request_fingerprint(actor_user_id, person_id, request_type) do
    Clubeira.Idempotency.fingerprint({1, actor_user_id, person_id, request_type})
  end

  defp fetch_platform_requests(repo, filters) do
    PrivacyRequest
    |> from(as: :request)
    |> maybe_filter_request_status(filters.status)
    |> after_platform_request(filters.after)
    |> order_by([request: request], desc: request.inserted_at, desc: request.id)
    |> limit(^filters.limit + 1)
    |> repo.all()
  end

  defp maybe_filter_request_status(query, nil), do: query

  defp maybe_filter_request_status(query, status) do
    where(query, [request: request], request.status == ^status)
  end

  defp after_platform_request(query, nil), do: query

  defp after_platform_request(query, %{at: at, id: id}) do
    where(
      query,
      [request: request],
      request.inserted_at < ^at or (request.inserted_at == ^at and request.id < ^id)
    )
  end

  defp parse_platform_request_filters(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_request} <- parse_request_cursor(Map.get(params, "after")),
         {:ok, status} <- parse_request_status(Map.get(params, "status")) do
      {:ok, %{limit: limit, after: after_request, status: status}}
    else
      :error -> {:error, :invalid_pagination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_page_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_limit(_limit), do: :error

  defp parse_request_cursor(nil), do: {:ok, nil}

  defp parse_request_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, <<unix_microsecond::signed-64, request_id::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, id} <- Ecto.UUID.load(request_id) do
      {:ok, %{at: at, id: id}}
    else
      _invalid -> :error
    end
  end

  defp parse_request_cursor(_cursor), do: :error

  defp parse_request_status(nil), do: {:ok, nil}
  defp parse_request_status(status) when status in @request_statuses, do: {:ok, status}
  defp parse_request_status(_status), do: {:error, :invalid_privacy_request_status}

  defp next_request_cursor(_requests, false), do: nil

  defp next_request_cursor(requests, true) do
    request = List.last(requests)
    unix_microsecond = DateTime.to_unix(request.inserted_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(request.id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :privacy_request_not_found}
    end
  end

  defp fetch_consent_purpose(repo, code, legal_document_version_id) do
    purpose =
      repo.one(
        from(purpose in ProcessingPurpose,
          join: version in DocumentVersion,
          on: version.id == purpose.legal_document_version_id,
          join: document in Document,
          on: document.id == version.legal_document_id,
          where:
            purpose.code == ^code and purpose.status == "active" and
              purpose.legal_basis == "consent" and
              purpose.legal_document_version_id == ^legal_document_version_id and
              document.status == "active" and document.audience == "consumer" and
              document.document_kind == "consent_notice" and
              fragment("? @> statement_timestamp()", version.effective_during),
          select: purpose,
          lock: "FOR SHARE"
        )
      )

    if purpose, do: {:ok, purpose}, else: {:error, :consent_unavailable}
  end

  defp lock_self_person(repo, actor_user_id) do
    case repo.one(self_person_query(actor_user_id) |> lock("FOR UPDATE")) do
      %Person{} = person -> {:ok, person}
      nil -> {:error, :profile_required}
    end
  end

  defp fetch_self_person(repo, actor_user_id) do
    case repo.one(self_person_query(actor_user_id)) do
      %Person{} = person -> {:ok, person}
      nil -> {:error, :profile_required}
    end
  end

  defp self_person_query(actor_user_id) do
    from(link in UserPersonLink,
      join: person in Person,
      on: person.id == link.person_id,
      where:
        link.user_id == ^actor_user_id and link.relationship == "self" and
          link.status == "active",
      select: person
    )
  end

  defp latest_events(repo, person_id) do
    repo.all(
      from(event in ConsentEvent,
        where: event.person_id == ^person_id,
        distinct: event.processing_purpose_id,
        order_by: [asc: event.processing_purpose_id, desc: event.occurred_at, desc: event.id]
      )
    )
    |> Map.new(&{&1.processing_purpose_id, &1})
  end

  defp latest_event(repo, person_id, purpose_id) do
    repo.one(
      from(event in ConsentEvent,
        where: event.person_id == ^person_id and event.processing_purpose_id == ^purpose_id,
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 1
      )
    )
  end

  defp current_state?(%ConsentEvent{} = event, command) do
    event.event_type == command.state and
      event.legal_document_version_id == command.legal_document_version_id
  end

  defp current_state?(nil, _command), do: false

  defp consent_view(purpose, person_id, event) do
    %{
      processing_purpose: %{
        code: purpose.code,
        name: purpose.name,
        legal_basis: purpose.legal_basis,
        current_legal_document_version_id: purpose.legal_document_version_id
      },
      state: if(event, do: event.event_type, else: "not_set"),
      legal_document_version_id: event && event.legal_document_version_id,
      person_id: person_id,
      occurred_at: event && event.occurred_at
    }
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
