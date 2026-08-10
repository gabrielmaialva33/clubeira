defmodule Clubeira.Redemptions.GrantIssuer do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Devices.ContractRedemptionDevice
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Devices.UserDeviceAuthorization
  alias Clubeira.Polos
  alias Clubeira.Redemptions.Grant
  alias Clubeira.Redemptions.GrantRequest
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Tenancy.Scope

  @spec issue(AccountScope.t(), String.t(), map()) ::
          {:ok, Grant.issued()}
          | {:error, :polo_not_found | :grant_not_available | Ecto.Changeset.t()}
  def issue(%AccountScope{} = account_scope, polo_slug, attributes) do
    with {:ok, request} <- GrantRequest.new(attributes),
         {:ok, route} <- Polos.resolve_route(polo_slug) do
      scope =
        Scope.new!(route.polo_id,
          actor_user_id: account_scope.user.id,
          request_id: account_scope.request_id
        )

      scope
      |> issue_in_scope(request)
      |> unwrap_transaction()
    end
  end

  defp issue_in_scope(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      case eligible_subject(repo, scope, request) do
        {allocation_id, device_id} ->
          {:ok, Grant.issue(scope, allocation_id, device_id, transaction_time(repo))}

        nil ->
          {:error, :grant_not_available}
      end
    end)
  end

  defp eligible_subject(repo, scope, request) do
    token_hash = GrantRequest.token_hash(request)

    EntitlementAllocation
    |> join_contract_chain()
    |> join_device_chain(token_hash, scope.actor_user_id)
    |> filter_requested_allocation(scope, request)
    |> filter_actor_contract(scope.actor_user_id)
    |> filter_current_contract()
    |> filter_current_authorizations()
    |> select([allocation, _subject, _cycle, _contract, device], {allocation.id, device.id})
    |> repo.one()
  end

  defp join_contract_chain(query) do
    query
    |> join(:inner, [allocation], subject in CycleEntitlementSubject,
      on:
        subject.id == allocation.cycle_entitlement_subject_id and
          subject.polo_id == allocation.polo_id
    )
    |> join(:inner, [allocation, subject], cycle in BenefitCycle,
      on:
        cycle.id == subject.benefit_cycle_id and cycle.polo_id == allocation.polo_id and
          cycle.access_contract_id == subject.access_contract_id
    )
    |> join(:inner, [allocation, subject], contract in AccessContract,
      on: contract.id == subject.access_contract_id and contract.polo_id == allocation.polo_id
    )
  end

  defp join_device_chain(query, token_hash, actor_user_id) do
    query
    |> join(:inner, [_allocation, _subject, _cycle, _contract], device in DeviceInstallation,
      on: device.installation_token_hash == ^token_hash
    )
    |> join(
      :inner,
      [_allocation, _subject, _cycle, _contract, device],
      user_device in UserDeviceAuthorization,
      on:
        user_device.user_id == ^actor_user_id and
          user_device.device_installation_id == device.id
    )
    |> join(
      :inner,
      [allocation, _subject, _cycle, contract, device],
      contract_device in ContractRedemptionDevice,
      on:
        contract_device.polo_id == allocation.polo_id and
          contract_device.access_contract_id == contract.id and
          contract_device.device_installation_id == device.id
    )
  end

  defp filter_requested_allocation(query, scope, request) do
    where(
      query,
      [allocation],
      allocation.id == ^request.entitlement_allocation_id and
        allocation.polo_id == ^scope.polo_id and allocation.available_units > 0
    )
  end

  defp filter_actor_contract(query, actor_user_id) do
    where(
      query,
      [_allocation, subject, _cycle, contract],
      subject.subject_kind == "contract" and contract.purchaser_user_id == ^actor_user_id and
        contract.status in ["active", "past_due"]
    )
  end

  defp filter_current_contract(query) do
    where(
      query,
      [_allocation, _subject, _cycle, contract],
      (is_nil(contract.starts_at) or contract.starts_at <= fragment("statement_timestamp()")) and
        (is_nil(contract.ends_at) or contract.ends_at > fragment("statement_timestamp()"))
    )
  end

  defp filter_current_authorizations(query) do
    where(
      query,
      [
        _allocation,
        _subject,
        cycle,
        _contract,
        device,
        user_device,
        contract_device
      ],
      cycle.status == "active" and
        fragment("? @> statement_timestamp()", cycle.benefits_during) and
        device.status == "active" and user_device.status == "active" and
        contract_device.status == "active" and
        fragment("? @> statement_timestamp()", contract_device.valid_during)
    )
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, grant}), do: {:ok, grant}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
