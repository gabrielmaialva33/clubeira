defmodule Clubeira.Idempotency do
  @moduledoc """
  Database-backed idempotency reservation and response storage.

  Redis may shield this boundary from load, but the PostgreSQL key remains the
  authority for command replay and request conflicts.

  Commands that reserve and finalize in one transaction serialize concurrent
  retries until a terminal response exists. `:request_in_progress` remains a
  deliberate result for workflows that persist a reservation before their
  terminal transition.
  """

  import Ecto.Query

  alias Clubeira.Idempotency.Key
  alias Clubeira.Tenancy.Scope

  @type reservation :: {:new, Ecto.UUID.t()} | {:replay, Key.t()} | {:error, atom()}

  @spec fingerprint(term()) :: binary()
  def fingerprint(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec reserve(module(), Scope.t(), String.t(), String.t(), binary(), DateTime.t()) ::
          reservation()
  def reserve(repo, %Scope{} = scope, command_scope, idempotency_key, request_hash, now) do
    id = uuid7()

    attributes = %{
      id: id,
      polo_id: scope.polo_id,
      user_id: scope.actor_user_id,
      scope: command_scope,
      idempotency_key: idempotency_key,
      request_sha256: request_hash,
      status: "processing",
      expires_at: DateTime.add(now, 86_400),
      inserted_at: now,
      updated_at: now
    }

    case repo.insert_all(Key, [attributes],
           on_conflict: :nothing,
           conflict_target: [:polo_id, :user_id, :scope, :idempotency_key],
           returning: [:id]
         ) do
      {1, [%{id: ^id}]} -> {:new, id}
      {0, []} -> classify_existing(repo, scope, command_scope, idempotency_key, request_hash)
    end
  end

  @spec complete!(module(), Ecto.UUID.t(), String.t(), Ecto.UUID.t(), map(), DateTime.t()) :: :ok
  def complete!(repo, id, resource_type, resource_id, response_body, now) do
    transition!(repo, id, %{
      status: "completed",
      response_status: 201,
      response_body: response_body,
      resource_type: resource_type,
      resource_id: resource_id,
      updated_at: now
    })
  end

  @spec fail!(
          module(),
          Ecto.UUID.t(),
          atom(),
          String.t() | nil,
          Ecto.UUID.t() | nil,
          DateTime.t()
        ) ::
          :ok
  def fail!(repo, id, reason, resource_type, resource_id, now) do
    fail!(repo, id, reason, resource_type, resource_id, now, [])
  end

  @spec fail!(
          module(),
          Ecto.UUID.t(),
          atom(),
          String.t() | nil,
          Ecto.UUID.t() | nil,
          DateTime.t(),
          keyword()
        ) :: :ok
  def fail!(repo, id, reason, resource_type, resource_id, now, options) do
    response_status = Keyword.get(options, :response_status, 422)

    unless response_status in 400..599 do
      raise ArgumentError, "response_status must be between 400 and 599"
    end

    transition!(repo, id, %{
      status: "failed",
      response_status: response_status,
      response_body: %{"reason" => Atom.to_string(reason)},
      resource_type: resource_type,
      resource_id: resource_id,
      updated_at: now
    })
  end

  defp classify_existing(repo, scope, command_scope, idempotency_key, request_hash) do
    existing =
      Key
      |> where(
        [key],
        key.polo_id == ^scope.polo_id and key.scope == ^command_scope and
          key.idempotency_key == ^idempotency_key
      )
      |> for_actor(scope.actor_user_id)
      |> lock("FOR UPDATE")
      |> repo.one!()

    cond do
      not :crypto.hash_equals(existing.request_sha256, request_hash) ->
        {:error, :idempotency_conflict}

      existing.status == "processing" ->
        {:error, :request_in_progress}

      true ->
        {:replay, existing}
    end
  end

  defp for_actor(query, nil), do: where(query, [key], is_nil(key.user_id))
  defp for_actor(query, user_id), do: where(query, [key], key.user_id == ^user_id)

  defp transition!(repo, id, attributes) do
    {count, nil} =
      repo.update_all(
        from(key in Key, where: key.id == ^id and key.status == "processing"),
        set: Map.to_list(attributes)
      )

    if count != 1 do
      raise "idempotency key #{id} did not transition from processing"
    end

    :ok
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
