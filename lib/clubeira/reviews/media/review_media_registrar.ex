defmodule Clubeira.Reviews.ReviewMediaRegistrar do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.MediaDescriptor
  alias Clubeira.Reviews.MediaVerifiers.Http
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewMedia
  alias Clubeira.Reviews.ReviewMediaRequest
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "reviews.register_media"
  @replay_reasons %{
    "review_media_conflict" => :review_media_conflict
  }

  @spec register(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{media: map(), created?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def register(%Scope{actor_user_id: nil}, _place_id, _review_id, _attributes),
    do: {:error, :actor_required}

  def register(%Scope{} = scope, place_id, review_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_uuid(place_id, :place_not_found),
         {:ok, review_id} <- cast_uuid(review_id, :review_not_found),
         {:ok, request} <- ReviewMediaRequest.new(attributes),
         {:ok, raw_descriptor} <- verifier().verify(request.storage_key),
         {:ok, descriptor} <- MediaDescriptor.new(raw_descriptor) do
      scope
      |> transact_registration(place_id, review_id, request, descriptor)
      |> unwrap_transaction()
    end
  end

  def register(_scope, _place_id, _review_id, _attributes), do: {:error, :actor_required}

  @spec public_url(Scope.t(), Ecto.UUID.t()) :: {:ok, String.t()} | {:error, atom()}
  def public_url(%Scope{} = scope, media_id) do
    with {:ok, media_id} <- cast_uuid(media_id, :review_media_not_found),
         {:ok, storage_key} <- fetch_public_storage_key(scope, media_id),
         {:ok, url} <- verifier().public_url(storage_key) do
      {:ok, url}
    else
      {:error, :media_not_found} -> {:error, :review_media_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def public_url(_scope, _media_id), do: {:error, :review_media_not_found}

  defp transact_registration(scope, place_id, review_id, request, descriptor) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, review} <- lock_authored_review(repo, scope, place_id, review_id),
           %ReviewRevision{} = revision <- latest_revision(repo, review.id) do
        repo
        |> reserve_registration(scope, review, revision, request, descriptor, now)
        |> transaction_outcome()
      else
        nil -> {:error, :review_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp reserve_registration(repo, scope, review, revision, request, descriptor, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, review, revision, request, descriptor),
           now
         ) do
      {:new, idempotency_id} ->
        insert_media(repo, scope, review, revision, request, descriptor, idempotency_id, now)

      {:replay, key} ->
        replay(repo, key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_media(repo, scope, review, revision, request, descriptor, idempotency_id, now) do
    changeset =
      %ReviewMedia{
        review_revision_id: revision.id,
        kind: descriptor.kind,
        storage_key: request.storage_key,
        content_type: descriptor.content_type,
        content_sha256: descriptor.content_sha256,
        position: request.position,
        width: descriptor.width,
        height: descriptor.height,
        duration_ms: descriptor.duration_ms,
        status: "ready",
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:storage_key,
        name: :review_media_storage_key_index
      )
      |> Ecto.Changeset.unique_constraint(:position,
        name: :review_media_review_revision_id_position_index
      )

    case repo.insert(changeset, mode: :savepoint) do
      {:ok, media} ->
        view = media_view(media)
        record_registration!(repo, scope, review, media, now)

        Idempotency.complete!(
          repo,
          idempotency_id,
          "review_media",
          media.id,
          persisted_media(view),
          now,
          response_status: 201
        )

        {:accepted, %{media: view, created?: true}}

      {:error, %Ecto.Changeset{}} ->
        reject!(repo, idempotency_id, now)
    end
  end

  defp lock_authored_review(repo, scope, place_id, review_id) do
    query =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> where(
        [review, redemption],
        review.id == ^review_id and review.place_id == ^place_id and
          review.author_user_id == ^scope.actor_user_id and review.status == "pending" and
          redemption.polo_id == ^scope.polo_id
      )
      |> select([review], review)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Review{} = review -> {:ok, review}
      nil -> {:error, :review_not_found}
    end
  end

  defp latest_revision(repo, review_id) do
    repo.one(
      from(revision in ReviewRevision,
        where: revision.review_id == ^review_id,
        order_by: [desc: revision.revision_number],
        limit: 1
      )
    )
  end

  defp record_registration!(repo, scope, review, media, now) do
    payload = %{
      "review_media_id" => media.id,
      "review_id" => review.id,
      "review_revision_id" => media.review_revision_id,
      "kind" => media.kind,
      "content_type" => media.content_type,
      "position" => media.position,
      "status" => media.status
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review_media",
      aggregate_id: media.id,
      aggregate_version: 1,
      event_type: "review_media.ready",
      topic: "reviews.media.ready",
      message_key: media.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "review_media.ready",
      resource_type: "review_media",
      resource_id: media.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp reject!(repo, idempotency_id, now) do
    reason = :review_media_conflict
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now, response_status: 409)
    {:denied, reason}
  end

  defp replay(
         repo,
         %Key{
           status: "completed",
           resource_type: "review_media",
           resource_id: media_id,
           response_status: 201
         }
       ) do
    case repo.get(ReviewMedia, media_id) do
      %ReviewMedia{} = media -> {:accepted, %{media: media_view(media), created?: false}}
      nil -> raise "completed review media key points to missing resource #{media_id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}),
    do: {:denied, Map.fetch!(@replay_reasons, reason)}

  defp replay(_repo, key), do: raise("invalid persisted review media response: #{inspect(key)}")

  defp fetch_public_storage_key(scope, media_id) do
    Repo.transact_in_polo(scope, fn repo ->
      storage_key =
        ReviewMedia
        |> join(:inner, [media], revision in ReviewRevision,
          on: revision.id == media.review_revision_id
        )
        |> join(:inner, [_media, revision], review in Review, on: review.id == revision.review_id)
        |> join(:inner, [_media, _revision, review], redemption in Redemption,
          on: redemption.id == review.source_redemption_id
        )
        |> where(
          [media, _revision, review, redemption],
          media.id == ^media_id and media.status == "ready" and
            review.status == "published" and redemption.polo_id == ^scope.polo_id
        )
        |> select([media], media.storage_key)
        |> repo.one()

      if storage_key, do: {:ok, storage_key}, else: {:error, :review_media_not_found}
    end)
  end

  defp media_view(media) do
    %{
      id: media.id,
      kind: media.kind,
      content_type: media.content_type,
      position: media.position,
      width: media.width,
      height: media.height,
      duration_ms: media.duration_ms,
      status: media.status,
      inserted_at: media.inserted_at
    }
  end

  defp persisted_media(media) do
    media
    |> Map.update!(:inserted_at, &DateTime.to_iso8601/1)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp request_hash(scope, review, revision, request, descriptor) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      review.id,
      revision.id,
      request.storage_key,
      request.position,
      descriptor.content_sha256
    })
  end

  defp verifier do
    Application.get_env(:clubeira, :review_media_verifier, Http)
  end

  defp cast_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp transaction_outcome({:accepted, _result} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:denied, _reason} = outcome), do: {:ok, outcome}
  defp transaction_outcome({:error, reason}), do: {:error, reason}

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
