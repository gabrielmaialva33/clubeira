defmodule Clubeira.Privacy.Consents do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Privacy.ConsentCommand
  alias Clubeira.Privacy.ConsentEvent
  alias Clubeira.Privacy.ProcessingPurpose
  alias Clubeira.Privacy.SubjectResolver
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @type state :: %{
          processing_purpose: map(),
          state: String.t(),
          legal_document_version_id: Ecto.UUID.t() | nil,
          person_id: Ecto.UUID.t(),
          occurred_at: DateTime.t() | nil
        }

  @spec put(ActorScope.t(), String.t(), ConsentCommand.t()) ::
          {:ok, state()} | {:error, atom() | Ecto.Changeset.t()}
  def put(%ActorScope{} = scope, purpose_code, %ConsentCommand{} = command) do
    Repo.transact_as_actor(scope, &put_in_scope(&1, scope, purpose_code, command))
  end

  @spec list(ActorScope.t()) :: {:ok, [state()]} | {:error, :profile_required}
  def list(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      with {:ok, person} <- SubjectResolver.fetch_self(repo, scope.actor_user_id) do
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

  defp put_in_scope(repo, scope, purpose_code, command) do
    now = transaction_time(repo)

    with {:ok, person} <- SubjectResolver.lock_self(repo, scope.actor_user_id),
         {:ok, purpose} <-
           fetch_consent_purpose(repo, purpose_code, command.legal_document_version_id) do
      put_state(repo, scope, person, purpose, command, now)
    end
  end

  defp put_state(repo, scope, person, purpose, command, now) do
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
