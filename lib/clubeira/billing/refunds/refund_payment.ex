defmodule Clubeira.Billing.RefundPayment do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Refund
  alias Clubeira.Billing.RefundPaymentGraph
  alias Clubeira.Billing.RefundRequest
  alias Clubeira.Billing.RefundSettler
  alias Clubeira.Idempotency
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @failure_reasons %{
    "payment_gateway_rejected" => :payment_gateway_rejected
  }

  @type reservation :: %{
          kind: :process | :replay,
          refund: Refund.t(),
          payment: struct() | nil,
          intent: struct() | nil,
          order: struct() | nil,
          account: struct() | nil,
          provider: struct() | nil
        }

  @spec request(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, Refund.t()} | {:error, atom() | Ecto.Changeset.t()}
  def request(%Scope{actor_user_id: nil}, _payment_id, _attributes),
    do: {:error, :billing_admin_required}

  def request(%Scope{} = scope, payment_id, attributes) when is_map(attributes) do
    with {:ok, payment_id} <- cast_payment_id(payment_id),
         {:ok, request} <- RefundRequest.new(attributes),
         {:ok, reservation} <- reserve(scope, payment_id, request) do
      process(scope, reservation)
    end
  end

  def request(_scope, _payment_id, _attributes), do: {:error, :billing_admin_required}

  defp reserve(scope, payment_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)
      request_hash = request_hash(scope, payment_id, request)

      with :ok <- Authorization.authorize(repo, scope, :manage_billing, now) do
        reserve_authorized(repo, scope, payment_id, request, request_hash, now)
      end
    end)
  end

  defp reserve_authorized(repo, scope, payment_id, request, request_hash, now) do
    case lock_existing_request(repo, scope, request.idempotency_key) do
      %Refund{} = refund ->
        resume_existing(repo, scope, refund, request_hash)

      nil ->
        reserve_new(repo, scope, payment_id, request, request_hash, now)
    end
  end

  defp lock_existing_request(repo, scope, idempotency_key) do
    Refund
    |> where(
      [refund],
      refund.polo_id == ^scope.polo_id and
        refund.requested_by_user_id == ^scope.actor_user_id and
        refund.idempotency_key == ^idempotency_key
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp resume_existing(repo, scope, refund, request_hash) do
    cond do
      not :crypto.hash_equals(refund.request_sha256, request_hash) ->
        {:error, :idempotency_conflict}

      refund.status == "succeeded" ->
        {:ok, replay_reservation(refund)}

      refund.status == "failed" ->
        {:error, persisted_failure(refund)}

      refund.status in ["requested", "processing"] ->
        with {:ok, graph} <- RefundPaymentGraph.lock_by_payment(repo, scope, refund.payment_id) do
          {:ok, process_reservation(refund, graph)}
        end

      true ->
        {:error, :refund_unavailable}
    end
  end

  defp reserve_new(repo, scope, payment_id, request, request_hash, now) do
    with {:ok, graph} <- RefundPaymentGraph.lock_by_payment(repo, scope, payment_id),
         :ok <- RefundPaymentGraph.refundable(graph),
         :ok <- ensure_no_live_refund(repo, scope, payment_id),
         {:ok, refund} <- insert_refund(repo, scope, graph.payment, request, request_hash, now) do
      {:ok, process_reservation(refund, graph)}
    end
  end

  defp ensure_no_live_refund(repo, scope, payment_id) do
    live? =
      Refund
      |> where(
        [refund],
        refund.polo_id == ^scope.polo_id and refund.payment_id == ^payment_id and
          refund.status in ["requested", "processing", "succeeded"]
      )
      |> select([refund], refund.id)
      |> limit(1)
      |> repo.one()
      |> is_binary()

    if live?, do: {:error, :refund_in_progress}, else: :ok
  end

  defp insert_refund(repo, scope, payment, request, request_hash, now) do
    %Refund{
      id: uuid7(),
      polo_id: scope.polo_id,
      payment_id: payment.id,
      requested_by_user_id: scope.actor_user_id,
      amount: payment.amount,
      reason: request.reason,
      status: "requested",
      idempotency_key: request.idempotency_key,
      request_sha256: request_hash,
      requested_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:idempotency_key,
      name: :refunds_actor_idempotency_uidx
    )
    |> Ecto.Changeset.unique_constraint(:payment_id, name: :refunds_live_payment_uidx)
    |> repo.insert()
  end

  defp process(_scope, %{kind: :replay, refund: refund}), do: {:ok, refund}

  defp process(scope, %{kind: :process} = reservation) do
    request = %{
      amount: reservation.payment.amount,
      currency: reservation.payment.currency,
      idempotency_key: reservation.refund.id,
      order_id: reservation.order.id,
      polo_id: scope.polo_id,
      provider_payment_reference: reservation.payment.provider_reference
    }

    case Gateways.refund_payment(
           reservation.provider.code,
           reservation.account,
           reservation.intent.provider_reference,
           request
         ) do
      {:ok, provider_refund} ->
        RefundSettler.settle_reserved(scope, reservation.refund.id, provider_refund)

      {:error, :payment_gateway_rejected} = error ->
        :ok = mark_failed(scope, reservation.refund.id, :payment_gateway_rejected)
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp mark_failed(scope, refund_id, reason) do
    Repo.transact_in_polo(scope, fn repo ->
      refund = lock_refund!(repo, scope, refund_id)

      if refund.status in ["requested", "processing"] do
        persist_failure(repo, scope, refund, reason)
      else
        {:ok, refund}
      end
    end)
    |> case do
      {:ok, %Refund{}} -> :ok
      {:error, error} -> raise "failed to persist refund rejection: #{inspect(error)}"
    end
  end

  defp persist_failure(repo, scope, refund, reason) do
    now = transaction_time(repo)

    failed =
      refund
      |> Ecto.Changeset.change(
        status: "failed",
        failure_reason: Atom.to_string(reason),
        completed_at: now,
        updated_at: now
      )
      |> repo.update!()

    Audit.record_tenant!(repo, scope, %{
      action: "refund.request_failed",
      resource_type: "refund",
      resource_id: refund.id,
      metadata: %{
        "payment_id" => refund.payment_id,
        "reason" => Atom.to_string(reason),
        "operator_reason" => refund.reason
      },
      occurred_at: now
    })

    {:ok, failed}
  end

  defp lock_refund!(repo, scope, refund_id) do
    Refund
    |> where([refund], refund.id == ^refund_id and refund.polo_id == ^scope.polo_id)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp replay_reservation(refund) do
    %{
      kind: :replay,
      refund: refund,
      payment: nil,
      intent: nil,
      order: nil,
      account: nil,
      provider: nil
    }
  end

  defp process_reservation(refund, graph) do
    Map.merge(graph, %{kind: :process, refund: refund})
  end

  defp persisted_failure(%Refund{failure_reason: reason}) do
    Map.fetch!(@failure_reasons, reason)
  end

  defp request_hash(scope, payment_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      payment_id,
      request.reason
    })
  end

  defp cast_payment_id(payment_id) do
    case Ecto.UUID.cast(payment_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :payment_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
