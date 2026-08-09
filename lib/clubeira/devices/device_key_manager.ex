defmodule Clubeira.Devices.DeviceKeyManager do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Audit
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Devices.DeviceKey
  alias Clubeira.Devices.DeviceKeyRegistrationRequest
  alias Clubeira.Devices.UserDeviceAuthorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @type key_result :: %{key: map(), created?: boolean(), rotated?: boolean()}

  @spec put(AccountScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, key_result()} | {:error, atom() | Ecto.Changeset.t()}
  def put(%AccountScope{} = account_scope, device_id, attributes) when is_map(attributes) do
    with {:ok, device_id} <- cast_device_id(device_id),
         {:ok, request} <- DeviceKeyRegistrationRequest.new(attributes) do
      actor_scope = actor_scope(account_scope)

      Repo.transact_as_actor(
        actor_scope,
        &put_in_scope(&1, actor_scope, device_id, request)
      )
    end
  end

  def put(%AccountScope{}, _device_id, attributes),
    do: DeviceKeyRegistrationRequest.new(attributes)

  @spec get_current(AccountScope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def get_current(%AccountScope{} = account_scope, device_id) do
    with {:ok, device_id} <- cast_device_id(device_id) do
      actor_scope = actor_scope(account_scope)

      Repo.transact_as_actor(actor_scope, &get_current_in_scope(&1, actor_scope, device_id))
    end
  end

  def get_current(_account_scope, _device_id), do: {:error, :device_key_not_found}

  defp put_in_scope(repo, scope, device_id, request) do
    now = transaction_time(repo)

    with {:ok, device} <- lock_owned_device(repo, scope, device_id, request) do
      put_key(repo, scope, device, request, now)
    end
  end

  defp get_current_in_scope(repo, scope, device_id) do
    case repo.one(current_key_query(scope.actor_user_id, device_id)) do
      %DeviceKey{} = key -> {:ok, key_view(key)}
      nil -> {:error, :device_key_not_found}
    end
  end

  defp current_key_query(actor_user_id, device_id) do
    DeviceKey
    |> join(:inner, [key], device in DeviceInstallation,
      on: device.id == key.device_installation_id
    )
    |> join(:inner, [key, _device], authorization in UserDeviceAuthorization,
      on: authorization.device_installation_id == key.device_installation_id
    )
    |> where(
      [key, device, authorization],
      key.device_installation_id == ^device_id and is_nil(key.revoked_at) and
        fragment("upper_inf(?)", key.valid_during) and device.status == "active" and
        authorization.user_id == ^actor_user_id and authorization.status == "active" and
        is_nil(authorization.revoked_at)
    )
    |> limit(1)
  end

  defp put_key(repo, scope, device, request, now) do
    thumbprint = :crypto.hash(:sha256, request.public_key)
    current = lock_current_key(repo, device.id)

    if same_key?(current, thumbprint) do
      {:ok, %{key: key_view(current), created?: false, rotated?: false}}
    else
      replace_key(repo, scope, device, request, current, thumbprint, now)
    end
  end

  defp same_key?(nil, _thumbprint), do: false
  defp same_key?(current, thumbprint), do: :crypto.hash_equals(current.key_thumbprint, thumbprint)

  defp replace_key(repo, scope, device, request, current, thumbprint, now) do
    if current, do: close_current_key!(repo, current, now)

    case insert_key(repo, device, request, thumbprint, now) do
      {:ok, key} -> key_replaced(repo, scope, key, current, now)
      {:error, %Ecto.Changeset{}} -> {:error, :device_key_conflict}
    end
  end

  defp key_replaced(repo, scope, key, current, now) do
    action = if current, do: "device_key.rotated", else: "device_key.registered"
    record_key_change!(repo, scope, key, action, now)

    {:ok,
     %{
       key: key_view(key),
       created?: is_nil(current),
       rotated?: not is_nil(current)
     }}
  end

  defp lock_owned_device(repo, scope, device_id, request) do
    authorized? =
      repo.exists?(
        from(authorization in UserDeviceAuthorization,
          where:
            authorization.user_id == ^scope.actor_user_id and
              authorization.device_installation_id == ^device_id and
              authorization.status == "active" and is_nil(authorization.revoked_at)
        )
      )

    device =
      if authorized? do
        repo.one(
          from(device in DeviceInstallation,
            where:
              device.id == ^device_id and
                device.installation_token_hash ==
                  ^DeviceKeyRegistrationRequest.token_hash(request) and
                device.status == "active",
            lock: "FOR UPDATE"
          )
        )
      end

    if device, do: {:ok, device}, else: {:error, :device_key_not_found}
  end

  defp lock_current_key(repo, device_id) do
    repo.one(
      from(key in DeviceKey,
        where:
          key.device_installation_id == ^device_id and is_nil(key.revoked_at) and
            fragment("upper_inf(?)", key.valid_during),
        lock: "FOR UPDATE"
      )
    )
  end

  defp close_current_key!(repo, key, now) do
    range = key.valid_during

    key
    |> Ecto.Changeset.change(
      valid_during: %Postgrex.Range{
        lower: range.lower,
        upper: now,
        lower_inclusive: true,
        upper_inclusive: false
      },
      revoked_at: now
    )
    |> repo.update!()
  end

  defp insert_key(repo, device, request, thumbprint, now) do
    %DeviceKey{
      device_installation_id: device.id,
      key_thumbprint: thumbprint,
      public_key: request.public_key,
      attestation_kind: "none",
      attestation_status: "unverified",
      valid_during: open_range(now),
      inserted_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:key_thumbprint,
      name: :device_keys_key_thumbprint_index
    )
    |> repo.insert(mode: :savepoint)
  end

  defp record_key_change!(repo, scope, key, action, now) do
    Audit.record_system!(repo, RequestContext.new!(scope.request_id), %{
      actor_user_id: scope.actor_user_id,
      action: action,
      resource_type: "device_key",
      resource_id: key.id,
      metadata: %{
        "device_installation_id" => key.device_installation_id,
        "attestation_kind" => key.attestation_kind,
        "attestation_status" => key.attestation_status
      },
      occurred_at: now
    })
  end

  defp key_view(key) do
    %{
      id: key.id,
      device_installation_id: key.device_installation_id,
      thumbprint: Base.url_encode64(key.key_thumbprint, padding: false),
      attestation: %{kind: key.attestation_kind, status: key.attestation_status},
      valid_from: key.valid_during.lower,
      valid_until: range_upper(key.valid_during),
      revoked_at: key.revoked_at
    }
  end

  defp range_upper(%Postgrex.Range{upper: :unbound}), do: nil
  defp range_upper(%Postgrex.Range{upper: upper}), do: upper

  defp open_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp actor_scope(account_scope) do
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp cast_device_id(device_id) do
    case Ecto.UUID.cast(device_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :device_key_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
