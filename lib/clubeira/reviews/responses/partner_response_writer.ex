defmodule Clubeira.Reviews.PartnerResponseWriter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.PartnerPlaceAccess
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Repo
  alias Clubeira.Reviews.PartnerResponseRequest
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewResponse
  alias Clubeira.Reviews.ReviewResponseRevision
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "reviews.put_partner_response"
  @replay_reasons %{
    "invalid_review_response_transition" => :invalid_review_response_transition
  }

  @spec put(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put(%Scope{actor_user_id: nil}, _review_id, _attributes),
    do: {:error, :partner_access_required}

  def put(%Scope{} = scope, review_id, attributes) when is_map(attributes) do
    with {:ok, review_id} <- cast_review_id(review_id),
         {:ok, request} <- PartnerResponseRequest.new(attributes) do
      scope
      |> transact_put(review_id, request)
      |> unwrap_transaction()
    end
  end

  def put(_scope, _review_id, _attributes), do: {:error, :partner_access_required}

  defp transact_put(scope, review_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, review} <- lock_published_review(repo, scope, review_id),
           {:ok, organization_id} <-
             PartnerPlaceAccess.authorized_organization(
               repo,
               scope,
               review.place_id,
               now
             ) do
        repo
        |> reserve_put(scope, review, organization_id, request, now)
        |> transaction_outcome()
      end
    end)
  end

  defp reserve_put(repo, scope, review, organization_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, review.id, organization_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        put_new(repo, scope, review, organization_id, request, idempotency_id, now)

      {:replay, key} ->
        replay(key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_new(repo, scope, review, organization_id, request, idempotency_id, now) do
    organization = repo.get!(Organization, organization_id)
    response = lock_response(repo, review.id, organization_id)

    case response do
      nil ->
        response = insert_response!(repo, scope, review, organization, now)
        revision = insert_revision!(repo, scope, response, 1, request.body, now)

        complete!(
          repo,
          scope,
          organization,
          response,
          revision,
          "published",
          idempotency_id,
          now
        )

      %ReviewResponse{status: "published"} = response ->
        current = latest_revision!(repo, response.id)

        if current.body == request.body do
          result = response_view(response, current, organization)
          complete_idempotency!(repo, idempotency_id, response.id, result, now)
          {:accepted, result}
        else
          response = touch_response!(repo, response, scope.actor_user_id, now)

          revision =
            insert_revision!(
              repo,
              scope,
              response,
              current.revision_number + 1,
              request.body,
              now
            )

          complete!(
            repo,
            scope,
            organization,
            response,
            revision,
            "updated",
            idempotency_id,
            now
          )
        end

      %ReviewResponse{} = response ->
        reject!(repo, response, idempotency_id, now)
    end
  end

  defp lock_published_review(repo, scope, review_id) do
    query =
      Review
      |> join(:inner, [review], redemption in Redemption,
        on: redemption.id == review.source_redemption_id
      )
      |> where(
        [review, redemption],
        review.id == ^review_id and redemption.polo_id == ^scope.polo_id
      )
      |> select([review], review)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Review{status: "published"} = review -> {:ok, review}
      %Review{} -> {:error, :review_not_responseable}
      nil -> {:error, :review_not_found}
    end
  end

  defp lock_response(repo, review_id, organization_id) do
    repo.one(
      from(response in ReviewResponse,
        where: response.review_id == ^review_id and response.organization_id == ^organization_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp latest_revision!(repo, response_id) do
    repo.one!(
      from(revision in ReviewResponseRevision,
        where: revision.review_response_id == ^response_id,
        order_by: [desc: revision.revision_number],
        limit: 1
      )
    )
  end

  defp insert_response!(repo, scope, review, organization, now) do
    %ReviewResponse{
      review_id: review.id,
      organization_id: organization.id,
      author_user_id: scope.actor_user_id,
      status: "published",
      published_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!()
  end

  defp touch_response!(repo, response, actor_user_id, now) do
    response
    |> Ecto.Changeset.change(author_user_id: actor_user_id, updated_at: now)
    |> repo.update!()
  end

  defp insert_revision!(repo, scope, response, number, body, now) do
    %ReviewResponseRevision{
      review_response_id: response.id,
      author_user_id: scope.actor_user_id,
      revision_number: number,
      body: body,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp complete!(
         repo,
         scope,
         organization,
         response,
         revision,
         event_name,
         idempotency_id,
         now
       ) do
    result = response_view(response, revision, organization)
    record_change!(repo, scope, response, revision, event_name, now)
    complete_idempotency!(repo, idempotency_id, response.id, result, now)
    {:accepted, result}
  end

  defp complete_idempotency!(repo, idempotency_id, response_id, result, now) do
    Idempotency.complete!(
      repo,
      idempotency_id,
      "review_response",
      response_id,
      persisted_response(result),
      now,
      response_status: 200
    )
  end

  defp record_change!(repo, scope, response, revision, event_name, now) do
    payload = %{
      "review_response_id" => response.id,
      "review_id" => response.review_id,
      "organization_id" => response.organization_id,
      "revision_number" => revision.revision_number,
      "status" => response.status,
      "published_at" => DateTime.to_iso8601(response.published_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "review_response",
      aggregate_id: response.id,
      aggregate_version: revision.revision_number,
      event_type: "review_response.#{event_name}",
      topic: "reviews.responses.#{event_name}",
      message_key: response.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "review_response.#{event_name}",
      resource_type: "review_response",
      resource_id: response.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp reject!(repo, response, idempotency_id, now) do
    reason = :invalid_review_response_transition

    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      "review_response",
      response.id,
      now,
      response_status: 409
    )

    {:denied, reason}
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "review_response",
         response_body: response
       }),
       do: {:accepted, restore_response(response)}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}),
    do: {:denied, Map.fetch!(@replay_reasons, reason)}

  defp replay(key), do: raise("invalid persisted partner response: #{inspect(key)}")

  defp response_view(response, revision, organization) do
    %{
      id: response.id,
      review_id: response.review_id,
      organization: %{
        id: organization.id,
        name: organization.trade_name || organization.legal_name
      },
      status: response.status,
      revision_number: revision.revision_number,
      body: revision.body,
      published_at: response.published_at,
      updated_at: response.updated_at
    }
  end

  defp persisted_response(response) do
    %{
      "id" => response.id,
      "review_id" => response.review_id,
      "organization" => %{
        "id" => response.organization.id,
        "name" => response.organization.name
      },
      "status" => response.status,
      "revision_number" => response.revision_number,
      "body" => response.body,
      "published_at" => DateTime.to_iso8601(response.published_at),
      "updated_at" => DateTime.to_iso8601(response.updated_at)
    }
  end

  defp restore_response(response) do
    %{
      id: response["id"],
      review_id: response["review_id"],
      organization: %{
        id: response["organization"]["id"],
        name: response["organization"]["name"]
      },
      status: response["status"],
      revision_number: response["revision_number"],
      body: response["body"],
      published_at: DateTime.from_iso8601(response["published_at"]) |> elem(1),
      updated_at: DateTime.from_iso8601(response["updated_at"]) |> elem(1)
    }
  end

  defp request_hash(scope, review_id, organization_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      review_id,
      organization_id,
      request.body
    })
  end

  defp cast_review_id(review_id) do
    case Ecto.UUID.cast(review_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :review_not_found}
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
