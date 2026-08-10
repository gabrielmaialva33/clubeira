defmodule Clubeira.Privacy.Requests do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.Platform.Authorization
  alias Clubeira.Privacy.Request, as: PrivacyRequest
  alias Clubeira.Privacy.RequestEvent
  alias Clubeira.Privacy.RequestSubmission
  alias Clubeira.Privacy.RequestTransition
  alias Clubeira.Privacy.SubjectResolver
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

  @spec submit(ActorScope.t(), RequestSubmission.t()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def submit(%ActorScope{} = scope, %RequestSubmission{} = submission) do
    Repo.transact_as_actor(scope, &submit_in_scope(&1, scope, submission))
  end

  @spec list(ActorScope.t()) :: {:ok, [map()]} | {:error, :profile_required}
  def list(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      with {:ok, _person} <- SubjectResolver.fetch_self(repo, scope.actor_user_id) do
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

  @spec list_platform(ActorScope.t(), map()) ::
          {:ok, %{requests: [map()], page: map()}} | {:error, atom()}
  def list_platform(%ActorScope{} = scope, params) when is_map(params) do
    with {:ok, filters} <- parse_platform_request_filters(params) do
      Repo.transact_as_actor(scope, &list_platform_in_scope(&1, scope, filters))
    end
  end

  @spec transition(ActorScope.t(), Ecto.UUID.t(), RequestTransition.t()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def transition(
        %ActorScope{} = scope,
        request_id,
        %RequestTransition{} = transition
      ) do
    Repo.transact_as_actor(
      scope,
      &transition_in_scope(&1, scope, request_id, transition)
    )
  end

  defp submit_in_scope(repo, scope, submission) do
    now = transaction_time(repo)

    with {:ok, person} <- SubjectResolver.lock_self(repo, scope.actor_user_id) do
      submit_for_person(repo, scope, person, submission, now)
    end
  end

  defp submit_for_person(repo, scope, person, submission, now) do
    request_hash = request_fingerprint(scope.actor_user_id, person.id, submission.request_type)

    case fetch_request(repo, scope.actor_user_id, submission.client_request_id) do
      %PrivacyRequest{} = request -> replay_request(repo, request, request_hash)
      nil -> insert_request(repo, scope, person, submission, request_hash, now)
    end
  end

  defp list_platform_in_scope(repo, scope, filters) do
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

  defp transition_in_scope(repo, scope, request_id, transition) do
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

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
