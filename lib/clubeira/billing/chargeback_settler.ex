defmodule Clubeira.Billing.ChargebackSettler do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.Chargeback
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentAccessLifecycle
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.RefundPaymentGraph
  alias Clubeira.Events
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Idempotency
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @maximum_provider_clock_skew_seconds 300

  @spec reconcile(
          Scope.t(),
          PaymentProvider.t(),
          MerchantAccount.t(),
          Gateways.chargeback()
        ) :: {:ok, Chargeback.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reconcile(
        %Scope{actor_user_id: nil} = scope,
        %PaymentProvider{} = provider,
        %MerchantAccount{} = account,
        provider_chargeback
      )
      when is_map(provider_chargeback) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, payment_graph} <-
             RefundPaymentGraph.lock_by_provider_payment(
               repo,
               scope,
               provider,
               account,
               provider_chargeback.provider_payment_reference
             ),
           :ok <- validate_chargeback(scope, payment_graph, provider_chargeback, now),
           {:ok, access_graph} <-
             PaymentAccessLifecycle.lock(repo, scope, payment_graph.order.id) do
        reconcile_event(
          repo,
          scope,
          payment_graph,
          access_graph,
          provider_chargeback,
          now
        )
      end
    end)
  end

  def reconcile(%Scope{}, %PaymentProvider{}, %MerchantAccount{}, _provider_chargeback),
    do: {:error, :service_scope_required}

  defp reconcile_event(repo, scope, payment_graph, access_graph, provider_chargeback, now) do
    case reserve_provider_event(repo, scope, payment_graph, provider_chargeback, now) do
      {:new, provider_event} ->
        reconcile_new_event(
          repo,
          scope,
          payment_graph,
          access_graph,
          provider_chargeback,
          provider_event,
          now
        )

      {:replay, _provider_event} ->
        case lock_chargeback(repo, scope, payment_graph.payment.id, provider_chargeback) do
          %Chargeback{} = chargeback -> {:ok, chargeback}
          nil -> {:error, :chargeback_reconciliation_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_new_event(
         repo,
         scope,
         payment_graph,
         access_graph,
         provider_chargeback,
         provider_event,
         now
       ) do
    with {:ok, chargeback, previous_status, state_changed?} <-
           persist_chargeback(repo, scope, payment_graph, provider_chargeback, now),
         {:ok, contract} <-
           PaymentAccessLifecycle.apply_chargeback!(
             repo,
             scope,
             access_graph,
             chargeback,
             previous_status,
             payment_graph,
             now
           ) do
      complete_new_event(
        repo,
        scope,
        payment_graph,
        provider_event,
        %{
          chargeback: chargeback,
          contract: contract,
          previous_status: previous_status,
          state_changed?: state_changed?
        },
        now
      )
    end
  end

  defp complete_new_event(repo, scope, payment_graph, provider_event, transition, now) do
    if transition.state_changed? do
      mark_financial_loss!(
        repo,
        payment_graph,
        transition.chargeback,
        transition.previous_status,
        now
      )

      record_chargeback!(
        repo,
        scope,
        transition.chargeback,
        payment_graph,
        transition.contract,
        now
      )
    end

    mark_provider_event_processed!(repo, provider_event, now)
    {:ok, transition.chargeback}
  end

  defp validate_chargeback(scope, graph, provider_chargeback, now) do
    with :ok <- validate_chargeback_identity(scope, graph, provider_chargeback),
         :ok <- validate_chargeback_amount(graph, provider_chargeback),
         :ok <- validate_chargebackable_graph(graph) do
      validate_chargeback_timestamps(graph, provider_chargeback, now)
    end
  end

  defp validate_chargeback_identity(scope, graph, provider_chargeback) do
    if provider_chargeback.polo_id == scope.polo_id and
         provider_chargeback.provider_payment_reference == graph.payment.provider_reference and
         provider_chargeback.currency == graph.payment.currency,
       do: :ok,
       else: {:error, :chargeback_reconciliation_mismatch}
  end

  defp validate_chargeback_amount(graph, provider_chargeback) do
    if Decimal.equal?(provider_chargeback.amount, graph.payment.amount),
      do: :ok,
      else: {:error, :partial_chargeback_unsupported}
  end

  defp validate_chargebackable_graph(graph) do
    if graph.payment.status in ["captured", "charged_back"] and
         graph.order.status in ["paid", "charged_back"],
       do: :ok,
       else: {:error, :payment_not_chargebackable}
  end

  defp validate_chargeback_timestamps(graph, provider_chargeback, now) do
    earliest = DateTime.add(graph.payment.captured_at, -@maximum_provider_clock_skew_seconds)
    latest = DateTime.add(now, @maximum_provider_clock_skew_seconds)

    if DateTime.before?(provider_chargeback.opened_at, earliest) or
         DateTime.before?(provider_chargeback.occurred_at, provider_chargeback.opened_at) or
         DateTime.after?(provider_chargeback.occurred_at, latest),
       do: {:error, :chargeback_timestamp_out_of_bounds},
       else: :ok
  end

  defp reserve_provider_event(repo, scope, graph, provider_chargeback, now) do
    external_event_id = provider_event_id(provider_chargeback)
    payload_sha256 = Idempotency.fingerprint(provider_chargeback.payload)

    event =
      PaymentProviderEvent
      |> where(
        [event],
        event.payment_provider_id == ^graph.provider.id and
          event.merchant_account_id == ^graph.account.id and
          event.external_event_id == ^external_event_id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case event do
      nil ->
        inserted =
          %PaymentProviderEvent{
            payment_provider_id: graph.provider.id,
            merchant_account_id: graph.account.id,
            polo_id: scope.polo_id,
            external_event_id: external_event_id,
            event_type: "chargeback.#{provider_chargeback.status}",
            payload: provider_chargeback.payload,
            payload_sha256: payload_sha256,
            received_at: now
          }
          |> repo.insert!()

        {:new, inserted}

      %PaymentProviderEvent{processed_at: %DateTime{}, payload_sha256: ^payload_sha256} = event ->
        {:replay, event}

      %PaymentProviderEvent{} ->
        {:error, :provider_event_conflict}
    end
  end

  defp persist_chargeback(repo, scope, graph, provider_chargeback, now) do
    case lock_chargeback(repo, scope, graph.payment.id, provider_chargeback) do
      nil ->
        chargeback =
          %Chargeback{
            polo_id: scope.polo_id,
            payment_id: graph.payment.id,
            provider_reference: provider_chargeback.provider_reference,
            amount: provider_chargeback.amount,
            reason_code: provider_chargeback.reason_code,
            status: provider_chargeback.status,
            opened_at: provider_chargeback.opened_at,
            closed_at: provider_chargeback.closed_at,
            inserted_at: now,
            updated_at: now
          }
          |> repo.insert!()

        {:ok, chargeback, nil, true}

      %Chargeback{} = chargeback ->
        with :ok <- matching_chargeback?(chargeback, provider_chargeback),
             :ok <- valid_transition?(chargeback.status, provider_chargeback.status) do
          previous_status = chargeback.status
          state_changed? = previous_status != provider_chargeback.status

          updated =
            chargeback
            |> Ecto.Changeset.change(
              reason_code: provider_chargeback.reason_code,
              status: provider_chargeback.status,
              closed_at: provider_chargeback.closed_at,
              updated_at: now
            )
            |> repo.update!()

          {:ok, updated, previous_status, state_changed?}
        end
    end
  end

  defp lock_chargeback(repo, scope, payment_id, provider_chargeback) do
    Chargeback
    |> where(
      [chargeback],
      chargeback.polo_id == ^scope.polo_id and chargeback.payment_id == ^payment_id and
        chargeback.provider_reference == ^provider_chargeback.provider_reference
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp matching_chargeback?(chargeback, provider_chargeback) do
    if Decimal.equal?(chargeback.amount, provider_chargeback.amount) and
         DateTime.compare(chargeback.opened_at, provider_chargeback.opened_at) == :eq do
      :ok
    else
      {:error, :chargeback_reconciliation_mismatch}
    end
  end

  defp valid_transition?(status, status), do: :ok
  defp valid_transition?("open", status) when status in ["under_review", "won", "lost"], do: :ok
  defp valid_transition?("under_review", status) when status in ["won", "lost"], do: :ok
  defp valid_transition?(_previous, _current), do: {:error, :invalid_chargeback_transition}

  defp mark_financial_loss!(_repo, _graph, %{status: status}, previous_status, _now)
       when status != "lost" or previous_status == "lost",
       do: :ok

  defp mark_financial_loss!(repo, graph, %Chargeback{status: "lost"}, _previous_status, now) do
    graph.payment
    |> Ecto.Changeset.change(status: "charged_back", charged_back_at: now)
    |> repo.update!()

    graph.order
    |> Ecto.Changeset.change(status: "charged_back", updated_at: now)
    |> repo.update!()
  end

  defp record_chargeback!(repo, scope, chargeback, graph, contract, now) do
    version = next_chargeback_version(repo, chargeback.id)

    payload = %{
      "chargeback_id" => chargeback.id,
      "payment_id" => graph.payment.id,
      "order_id" => graph.order.id,
      "access_contract_id" => contract.id,
      "currency" => graph.payment.currency,
      "amount" => Decimal.to_string(chargeback.amount),
      "status" => chargeback.status
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "chargeback",
      aggregate_id: chargeback.id,
      aggregate_version: version,
      event_type: "chargeback.#{chargeback.status}",
      topic: "billing.chargebacks.#{chargeback.status}",
      message_key: chargeback.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "chargeback.#{chargeback.status}",
      resource_type: "chargeback",
      resource_id: chargeback.id,
      metadata: Map.put(payload, "reason_code", chargeback.reason_code),
      occurred_at: now
    })
  end

  defp next_chargeback_version(repo, chargeback_id) do
    current =
      DomainEvent
      |> where(
        [event],
        event.aggregate_type == "chargeback" and event.aggregate_id == ^chargeback_id
      )
      |> repo.aggregate(:max, :aggregate_version)

    (current || 0) + 1
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp provider_event_id(provider_chargeback) do
    "chargeback:#{provider_chargeback.provider_reference}:#{provider_chargeback.status}:#{DateTime.to_iso8601(provider_chargeback.occurred_at)}"
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
