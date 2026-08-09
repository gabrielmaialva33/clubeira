defmodule Clubeira.Devices do
  @moduledoc """
  Authenticated installation enrollment for redemption.

  The client proves possession with a high-entropy installation token. Only its
  digest is persisted; user, polo, and contract authority are derived from the
  authenticated account and locked database records.
  """

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Audit
  alias Clubeira.Devices.ContractRedemptionDevice
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Devices.DeviceKeyManager
  alias Clubeira.Devices.RedemptionEnrollmentRequest
  alias Clubeira.Devices.UserDeviceAuthorization
  alias Clubeira.Events
  alias Clubeira.Polos
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Tenancy.Scope

  @type enrollment :: %{
          device: DeviceInstallation.t(),
          contract_device: ContractRedemptionDevice.t(),
          created?: boolean()
        }

  @type enrollment_error ::
          :polo_not_found
          | :contract_not_found
          | :device_unavailable
          | :installation_conflict
          | :device_limit_reached
          | Ecto.Changeset.t()

  @doc """
  Registers or rotates the current Ed25519 proof-of-possession key for an owned device.
  """
  @spec put_device_key(AccountScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, DeviceKeyManager.key_result()} | {:error, term()}
  defdelegate put_device_key(account_scope, device_id, attributes),
    to: DeviceKeyManager,
    as: :put

  @doc """
  Returns only safe metadata for the current key of an owned device.
  """
  @spec get_current_device_key(AccountScope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate get_current_device_key(account_scope, device_id),
    to: DeviceKeyManager,
    as: :get_current

  @spec enroll_redemption_device(AccountScope.t(), String.t(), map()) ::
          {:ok, enrollment()} | {:error, enrollment_error()}
  def enroll_redemption_device(%AccountScope{} = account_scope, polo_slug, attributes)
      when is_binary(polo_slug) and is_map(attributes) do
    with {:ok, request} <- RedemptionEnrollmentRequest.new(attributes),
         {:ok, route} <- Polos.resolve_route(polo_slug) do
      scope =
        Scope.new!(route.polo_id,
          actor_user_id: account_scope.user.id,
          request_id: account_scope.request_id
        )

      scope
      |> transact_enrollment(request)
      |> unwrap_transaction()
    end
  end

  def enroll_redemption_device(%AccountScope{}, _polo_slug, attributes) do
    RedemptionEnrollmentRequest.new(attributes)
  end

  defp transact_enrollment(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, {contract, policy}} <- lock_contract(repo, scope, request, now),
           {:ok, device} <- find_or_create_device(repo, request, now),
           :ok <- authorize_user_device(repo, scope, device, now) do
        authorize_contract_device(repo, scope, contract, policy, device, now)
      end
    end)
  end

  defp lock_contract(repo, scope, request, now) do
    query =
      AccessContract
      |> join(:inner, [contract], policy in PoloPolicyVersion,
        on: policy.id == contract.polo_policy_version_id and policy.polo_id == contract.polo_id
      )
      |> filter_contract_identity(scope, request)
      |> filter_current_contract(now)
      |> lock("FOR UPDATE")
      |> select([contract, policy], {contract, policy})

    case repo.one(query) do
      {%AccessContract{}, %PoloPolicyVersion{}} = result -> {:ok, result}
      nil -> {:error, :contract_not_found}
    end
  end

  defp filter_contract_identity(query, scope, request) do
    where(
      query,
      [contract],
      contract.id == ^request.access_contract_id and contract.polo_id == ^scope.polo_id and
        contract.purchaser_user_id == ^scope.actor_user_id and
        contract.status in ["active", "past_due"]
    )
  end

  defp filter_current_contract(query, now) do
    where(
      query,
      [contract],
      (is_nil(contract.starts_at) or contract.starts_at <= ^now) and
        (is_nil(contract.ends_at) or contract.ends_at > ^now)
    )
  end

  defp find_or_create_device(repo, request, now) do
    token_hash = RedemptionEnrollmentRequest.token_hash(request)

    %DeviceInstallation{
      installation_token_hash: token_hash,
      platform: request.platform,
      status: "active",
      first_seen_at: now,
      last_seen_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:installation_token_hash]
    )

    device =
      repo.one!(
        from device in DeviceInstallation,
          where: device.installation_token_hash == ^token_hash,
          lock: "FOR UPDATE"
      )

    cond do
      device.status != "active" ->
        {:error, :device_unavailable}

      device.platform != request.platform ->
        {:error, :installation_conflict}

      true ->
        {1, _devices} =
          repo.update_all(
            from(candidate in DeviceInstallation, where: candidate.id == ^device.id),
            set: [last_seen_at: now, updated_at: now]
          )

        {:ok, %{device | last_seen_at: now, updated_at: now}}
    end
  end

  defp authorize_user_device(repo, scope, device, now) do
    %UserDeviceAuthorization{
      user_id: scope.actor_user_id,
      device_installation_id: device.id,
      status: "active",
      authorized_at: now,
      inserted_at: now
    }
    |> repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:user_id, :device_installation_id]
    )

    case repo.get_by!(UserDeviceAuthorization,
           user_id: scope.actor_user_id,
           device_installation_id: device.id
         ) do
      %UserDeviceAuthorization{status: "active"} -> :ok
      %UserDeviceAuthorization{} -> {:error, :device_unavailable}
    end
  end

  defp authorize_contract_device(repo, scope, contract, policy, device, now) do
    case current_contract_device(repo, contract.id, device.id) do
      %ContractRedemptionDevice{} = contract_device ->
        {:ok, %{device: device, contract_device: contract_device, created?: false}}

      nil ->
        create_contract_device(repo, scope, contract, policy, device, now)
    end
  end

  defp current_contract_device(repo, contract_id, device_id) do
    repo.one(
      from contract_device in ContractRedemptionDevice,
        where:
          contract_device.access_contract_id == ^contract_id and
            contract_device.device_installation_id == ^device_id and
            contract_device.status == "active" and
            fragment("? @> statement_timestamp()", contract_device.valid_during)
    )
  end

  defp create_contract_device(repo, scope, contract, policy, device, now) do
    if current_device_count(repo, contract.id) >= policy.max_authorized_devices do
      {:error, :device_limit_reached}
    else
      contract_device =
        %ContractRedemptionDevice{
          polo_id: scope.polo_id,
          access_contract_id: contract.id,
          device_installation_id: device.id,
          valid_during: open_range(now),
          status: "active",
          inserted_at: now
        }
        |> repo.insert!()

      record_authorization!(repo, scope, contract_device, now)

      {:ok, %{device: device, contract_device: contract_device, created?: true}}
    end
  end

  defp current_device_count(repo, contract_id) do
    repo.aggregate(
      from(contract_device in ContractRedemptionDevice,
        where:
          contract_device.access_contract_id == ^contract_id and
            contract_device.status == "active" and
            fragment("? @> statement_timestamp()", contract_device.valid_during)
      ),
      :count
    )
  end

  defp record_authorization!(repo, scope, contract_device, now) do
    payload = %{
      "access_contract_id" => contract_device.access_contract_id,
      "device_installation_id" => contract_device.device_installation_id
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "contract_redemption_device",
      aggregate_id: contract_device.id,
      aggregate_version: 1,
      event_type: "redemption_device.authorized",
      topic: "redemption_devices.authorized",
      message_key: contract_device.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "redemption_device.authorized",
      resource_type: "contract_redemption_device",
      resource_id: contract_device.id,
      metadata: payload,
      occurred_at: now
    })

    :ok
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp open_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp unwrap_transaction({:ok, enrollment}), do: {:ok, enrollment}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
