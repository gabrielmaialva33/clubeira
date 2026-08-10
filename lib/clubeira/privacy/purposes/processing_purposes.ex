defmodule Clubeira.Privacy.ProcessingPurposes do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Platform.Authorization
  alias Clubeira.Privacy.ProcessingPurpose
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @code_pattern ~r/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/

  @spec list(ActorScope.t()) :: {:ok, [map()]} | {:error, atom()}
  def list(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      now = transaction_time(repo)

      with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now) do
        purposes =
          repo.all(
            from(purpose in ProcessingPurpose,
              order_by: [asc: purpose.code]
            )
          )

        {:ok, Enum.map(purposes, &purpose_view/1)}
      end
    end)
  end

  @spec put(ActorScope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put(%ActorScope{} = scope, code, attributes) do
    with :ok <- validate_code(code) do
      Repo.transact_as_actor(scope, &put_in_scope(&1, scope, code, attributes))
    end
  end

  defp put_in_scope(repo, scope, code, attributes) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now),
         :ok <- validate_legal_document(repo, attributes) do
      lock_code!(repo, code)
      put_record(repo, scope, code, attributes, now)
    end
  end

  defp put_record(repo, scope, code, attributes, now) do
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
      {:ok, purpose_view(purpose)}
    else
      case repo.insert_or_update(changeset) do
        {:ok, saved} ->
          record_change!(repo, scope, saved, now)
          {:ok, purpose_view(saved)}

        {:error, %Ecto.Changeset{} = invalid} ->
          {:error, invalid}
      end
    end
  end

  defp record_change!(repo, scope, purpose, now) do
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

  defp validate_code(code) when byte_size(code) in 2..100 do
    if Regex.match?(@code_pattern, code),
      do: :ok,
      else: {:error, :invalid_processing_purpose}
  end

  defp validate_code(_code), do: {:error, :invalid_processing_purpose}

  defp validate_legal_document(repo, attributes) do
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

  defp lock_code!(repo, code) do
    repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["privacy.processing_purpose:" <> code]
    )

    :ok
  end

  defp purpose_view(purpose) do
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

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
