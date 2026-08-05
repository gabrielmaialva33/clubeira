defmodule Clubeira.Redemptions do
  @moduledoc """
  Atomic online redemption boundary and member history.

  `list_for_member/2` reads only successful redemptions belonging to the scoped
  actor and polo. `confirm/2` consumes a previously issued entitlement and
  commits the attempt, redemption, ledger mutation, audit event, domain event,
  idempotency response, and outbox message together. It does not issue or
  authenticate QR tokens; that protocol belongs to a separate boundary that
  must call this one only after a confirmation proof has been authenticated.
  """

  import Ecto.Query

  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Redemptions.AuthenticatedConfirmation
  alias Clubeira.Redemptions.ConfirmedRequest
  alias Clubeira.Redemptions.Eligibility
  alias Clubeira.Redemptions.GrantIssuer
  alias Clubeira.Redemptions.Recorder
  alias Clubeira.Redemptions.Redemption
  alias Clubeira.Redemptions.RedemptionAttempt
  alias Clubeira.Redemptions.RedemptionReader
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "redemptions.confirm"
  @replay_reasons %{
    "validation_point_unavailable" => :validation_point_unavailable,
    "place_unavailable" => :place_unavailable,
    "device_unavailable" => :device_unavailable,
    "actor_not_entitled" => :actor_not_entitled,
    "contract_inactive" => :contract_inactive,
    "cycle_inactive" => :cycle_inactive,
    "entitlement_configuration_invalid" => :entitlement_configuration_invalid,
    "offer_inactive" => :offer_inactive,
    "offer_not_available_at_place" => :offer_not_available_at_place,
    "outside_availability_window" => :outside_availability_window,
    "offer_blackout" => :offer_blackout,
    "allocation_not_valid_at_place" => :allocation_not_valid_at_place,
    "device_not_authorized" => :device_not_authorized,
    "entitlement_exhausted" => :entitlement_exhausted,
    "entitlement_not_found" => :entitlement_not_found,
    "nonce_replayed" => :nonce_replayed
  }

  @type error_reason ::
          :actor_required
          | :idempotency_conflict
          | :request_in_progress
          | :entitlement_not_found
          | :nonce_replayed
          | Eligibility.reason()

  @spec list_for_member(Scope.t(), map()) ::
          {:ok, %{redemptions: [map()], page: map()}} | {:error, term()}
  defdelegate list_for_member(scope, params), to: RedemptionReader, as: :list

  @spec issue_grant(Clubeira.Accounts.Scope.t(), String.t(), map()) ::
          {:ok, Clubeira.Redemptions.Grant.issued()} | {:error, term()}
  defdelegate issue_grant(account_scope, polo_slug, attributes), to: GrantIssuer, as: :issue

  @spec confirm_grant(String.t(), map(), Clubeira.Accounts.RequestContext.t()) ::
          {:ok, Redemption.t()} | {:error, term()}
  defdelegate confirm_grant(polo_slug, attributes, context),
    to: AuthenticatedConfirmation,
    as: :confirm

  @spec confirm(Scope.t(), map()) ::
          {:ok, Redemption.t()} | {:error, error_reason() | Ecto.Changeset.t()}
  def confirm(%Scope{actor_user_id: nil}, _attributes), do: {:error, :actor_required}

  def confirm(%Scope{} = scope, attributes) do
    with {:ok, request} <- ConfirmedRequest.new(attributes) do
      nonce_hash = ConfirmedRequest.nonce_hash(request)
      request_hash = request_hash(scope, request, nonce_hash)

      scope
      |> transact_confirmation(request, nonce_hash, request_hash)
      |> unwrap_transaction()
    end
  end

  def confirm(_scope, _attributes), do: {:error, :actor_required}

  defp transact_confirmation(scope, request, nonce_hash, request_hash) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      outcome =
        case Idempotency.reserve(
               repo,
               scope,
               @idempotency_scope,
               request.idempotency_key,
               request_hash,
               now
             ) do
          {:new, idempotency_id} ->
            execute_new(repo, scope, request, nonce_hash, idempotency_id, now)

          {:replay, key} ->
            replay(repo, key)

          {:error, reason} ->
            {:denied, reason}
        end

      {:ok, outcome}
    end)
  end

  defp execute_new(repo, scope, request, nonce_hash, idempotency_id, now) do
    lock_nonce!(repo, nonce_hash)

    if nonce_used?(repo, scope, nonce_hash) do
      reject_request!(repo, scope, request, idempotency_id, :nonce_replayed, now)
    else
      evaluate_entitlement(repo, scope, request, nonce_hash, idempotency_id, now)
    end
  end

  defp evaluate_entitlement(repo, scope, request, nonce_hash, idempotency_id, now) do
    case Eligibility.lock(repo, scope, request, now) do
      {:ok, %Eligibility{reason: nil} = eligibility} ->
        redemption = Recorder.accept!(repo, scope, request, eligibility, nonce_hash, now)

        Idempotency.complete!(
          repo,
          idempotency_id,
          "redemption",
          redemption.id,
          %{"redemption_id" => redemption.id},
          now
        )

        {:accepted, redemption}

      {:ok, %Eligibility{reason: reason} = eligibility} ->
        reject_eligibility!(
          repo,
          scope,
          request,
          eligibility,
          nonce_hash,
          idempotency_id,
          reason,
          now
        )

      {:error, :entitlement_not_found} ->
        reject_request!(repo, scope, request, idempotency_id, :entitlement_not_found, now)
    end
  end

  defp reject_eligibility!(
         repo,
         scope,
         request,
         eligibility,
         nonce_hash,
         idempotency_id,
         reason,
         now
       ) do
    {resource_type, resource_id} =
      if Eligibility.recordable_attempt?(eligibility) do
        Recorder.deny!(repo, scope, request, eligibility, nonce_hash, reason, now)
      else
        Recorder.deny_request!(repo, scope, request, idempotency_id, reason, now)
      end

    Idempotency.fail!(repo, idempotency_id, reason, resource_type, resource_id, now)
    {:denied, reason}
  end

  defp reject_request!(repo, scope, request, idempotency_id, reason, now) do
    {resource_type, resource_id} =
      Recorder.deny_request!(repo, scope, request, idempotency_id, reason, now)

    Idempotency.fail!(repo, idempotency_id, reason, resource_type, resource_id, now)
    {:denied, reason}
  end

  defp nonce_used?(repo, scope, nonce_hash) do
    repo.exists?(
      from attempt in RedemptionAttempt,
        where: attempt.polo_id == ^scope.polo_id and attempt.request_nonce_hash == ^nonce_hash
    )
  end

  defp lock_nonce!(repo, nonce_hash) do
    encoded_nonce = Base.encode16(nonce_hash, case: :lower)
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [encoded_nonce])
    :ok
  end

  defp replay(repo, %Key{status: "completed", resource_type: "redemption", resource_id: id}) do
    case repo.get(Redemption, id) do
      %Redemption{} = redemption -> {:accepted, redemption}
      nil -> raise "completed redemption idempotency key points to missing resource #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted idempotency response: #{inspect(key)}"
  end

  defp request_hash(scope, request, nonce_hash) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.entitlement_allocation_id,
      request.validation_point_id,
      request.device_installation_id,
      nonce_hash
    })
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, redemption}}), do: {:ok, redemption}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
