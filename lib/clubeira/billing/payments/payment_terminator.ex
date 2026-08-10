defmodule Clubeira.Billing.PaymentTerminator do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "billing.terminate_payment"
  @live_statuses ~w(created requires_action processing authorized)
  @terminal_statuses ~w(failed cancelled expired)
  @replay_reasons %{
    "merchant_account_unavailable" => :merchant_account_unavailable,
    "order_not_found" => :order_not_found,
    "order_not_payable" => :order_not_payable,
    "payment_intent_mismatch" => :payment_intent_mismatch,
    "payment_intent_not_found" => :payment_intent_not_found,
    "payment_intent_unavailable" => :payment_intent_unavailable,
    "payment_record_invalid" => :payment_record_invalid,
    "payment_reference_conflict" => :payment_reference_conflict,
    "provider_event_already_received" => :provider_event_already_received
  }

  @type terminal_payment :: Clubeira.Billing.Gateways.terminal_payment()

  @spec terminate(
          Scope.t(),
          PaymentProvider.t(),
          MerchantAccount.t(),
          String.t(),
          terminal_payment()
        ) :: {:ok, PaymentIntent.t()} | {:error, atom()}
  def terminate(
        %Scope{actor_user_id: nil} = scope,
        %PaymentProvider{} = provider,
        %MerchantAccount{payment_provider_id: provider_id} = account,
        external_event_id,
        %{status: status} = payment
      )
      when provider_id == provider.id and is_binary(external_event_id) and
             status in @terminal_statuses do
    idempotency_key = idempotency_key(provider, account, external_event_id)
    request_hash = request_hash(scope, provider, account, external_event_id, payment)

    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      outcome =
        case Idempotency.reserve(
               repo,
               scope,
               @idempotency_scope,
               idempotency_key,
               request_hash,
               now
             ) do
          {:new, idempotency_id} ->
            terminate_new(
              repo,
              scope,
              provider,
              account,
              external_event_id,
              payment,
              idempotency_id,
              now
            )

          {:replay, key} ->
            replay(repo, key)

          {:error, reason} ->
            {:denied, reason}
        end

      {:ok, outcome}
    end)
    |> unwrap_transaction()
  end

  def terminate(_scope, _provider, _account, _external_event_id, _payment) do
    {:error, :invalid_terminal_payment}
  end

  defp terminate_new(
         repo,
         scope,
         provider,
         account,
         external_event_id,
         payment,
         idempotency_id,
         now
       ) do
    with :ok <- lock_merchant_account_link(repo, scope, provider, account),
         {:ok, order} <- lock_order(repo, scope, payment.order_id),
         {:ok, provider_event} <-
           insert_provider_event(
             repo,
             scope,
             provider,
             account,
             external_event_id,
             payment,
             now
           ) do
      terminate_received_event(
        repo,
        scope,
        order,
        account,
        payment,
        provider_event,
        idempotency_id,
        now
      )
    else
      {:error, reason} -> reject!(repo, idempotency_id, reason, nil, now)
    end
  end

  defp terminate_received_event(
         repo,
         scope,
         order,
         account,
         payment,
         provider_event,
         idempotency_id,
         now
       ) do
    case terminate_intent(repo, scope, order, account, payment, now) do
      {:ok, outcome} ->
        intent = terminal_intent(outcome)

        if match?({:transitioned, _intent, _previous_status}, outcome) do
          record_termination!(repo, scope, intent, terminal_previous_status(outcome), now)
        end

        mark_provider_event_processed!(repo, provider_event, now)

        Idempotency.complete!(
          repo,
          idempotency_id,
          "payment_intent",
          intent.id,
          %{"payment_intent_id" => intent.id},
          now
        )

        {:accepted, intent}

      {:error, reason} ->
        reject!(repo, idempotency_id, reason, provider_event, now)
    end
  end

  defp lock_merchant_account_link(repo, scope, provider, account) do
    query =
      from assignment in PoloMerchantAccount,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.payment_provider_id == ^provider.id and
            assignment.merchant_account_id == ^account.id,
        lock: "FOR SHARE",
        select: assignment.merchant_account_id

    if repo.one(query), do: :ok, else: {:error, :merchant_account_unavailable}
  end

  defp lock_order(repo, scope, order_id) do
    query =
      from order in Order,
        where: order.id == ^order_id and order.polo_id == ^scope.polo_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Order{status: status} = order when status in ["pending", "awaiting_payment"] ->
        {:ok, order}

      %Order{} ->
        {:error, :order_not_payable}

      nil ->
        {:error, :order_not_found}
    end
  end

  defp insert_provider_event(
         repo,
         scope,
         provider,
         account,
         external_event_id,
         payment,
         now
       ) do
    id = uuid7()

    attributes = %{
      id: id,
      payment_provider_id: provider.id,
      merchant_account_id: account.id,
      polo_id: scope.polo_id,
      external_event_id: external_event_id,
      event_type: "payment.#{payment.status}",
      payload: payment.payload,
      payload_sha256: Idempotency.fingerprint(payment.payload),
      received_at: now
    }

    case repo.insert_all(PaymentProviderEvent, [attributes],
           on_conflict: :nothing,
           conflict_target: [:payment_provider_id, :merchant_account_id, :external_event_id],
           returning: [:id]
         ) do
      {1, [%{id: ^id}]} -> {:ok, repo.get!(PaymentProviderEvent, id)}
      {0, []} -> {:error, :provider_event_already_received}
    end
  end

  defp terminate_intent(repo, scope, order, account, payment, now) do
    case lock_intent(repo, scope, order, account, payment.provider_reference) do
      %PaymentIntent{} = intent -> update_intent(repo, intent, order, payment, now)
      nil -> {:error, :payment_intent_not_found}
    end
  end

  defp lock_intent(repo, scope, order, account, provider_reference) do
    exact_query =
      from intent in PaymentIntent,
        where:
          intent.polo_id == ^scope.polo_id and intent.order_id == ^order.id and
            intent.merchant_account_id == ^account.id and
            intent.provider_reference == ^provider_reference,
        lock: "FOR UPDATE"

    repo.one(exact_query) || lock_unreferenced_intent(repo, scope, order, account)
  end

  defp lock_unreferenced_intent(repo, scope, order, account) do
    from(intent in PaymentIntent,
      where:
        intent.polo_id == ^scope.polo_id and intent.order_id == ^order.id and
          intent.merchant_account_id == ^account.id and is_nil(intent.provider_reference) and
          intent.status == "created",
      lock: "FOR UPDATE"
    )
    |> repo.one()
  end

  defp update_intent(repo, intent, order, payment, now) do
    with :ok <- validate_intent_match(intent, order, payment) do
      transition_intent(repo, intent, payment, now)
    end
  end

  defp validate_intent_match(intent, order, payment) do
    if intent.order_id == order.id and intent.currency == payment.currency and
         Decimal.equal?(intent.amount, payment.amount) do
      :ok
    else
      {:error, :payment_intent_mismatch}
    end
  end

  defp transition_intent(repo, intent, payment, now) do
    cond do
      intent.status == payment.status and
          intent.provider_reference == payment.provider_reference ->
        {:ok, {:reconciled, intent}}

      intent.status not in @live_statuses ->
        {:error, :payment_intent_unavailable}

      true ->
        persist_transition(repo, intent, payment, now)
    end
  end

  defp persist_transition(repo, intent, payment, now) do
    previous_status = intent.status

    intent
    |> Ecto.Changeset.change(
      provider_reference: payment.provider_reference,
      status: payment.status,
      next_action: %{},
      updated_at: now
    )
    |> Ecto.Changeset.unique_constraint(:provider_reference,
      name: :payment_intents_provider_reference_uidx
    )
    |> repo.update(mode: :savepoint)
    |> case do
      {:ok, updated} -> {:ok, {:transitioned, updated, previous_status}}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, update_error(changeset)}
    end
  end

  defp update_error(changeset) do
    if constraint_error?(changeset, "payment_intents_provider_reference_uidx") do
      :payment_reference_conflict
    else
      :payment_record_invalid
    end
  end

  defp constraint_error?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      to_string(options[:constraint_name]) == name
    end)
  end

  defp record_termination!(repo, scope, intent, previous_status, now) do
    payload = %{
      "payment_intent_id" => intent.id,
      "order_id" => intent.order_id,
      "status" => intent.status,
      "currency" => intent.currency,
      "amount" => Decimal.to_string(intent.amount)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "payment_intent",
      aggregate_id: intent.id,
      aggregate_version: if(previous_status == "created", do: 1, else: 2),
      event_type: "payment_intent.#{intent.status}",
      topic: "billing.payment_intents.#{intent.status}",
      message_key: intent.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "payment_intent.#{intent.status}",
      resource_type: "payment_intent",
      resource_id: intent.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp mark_provider_event_processed!(repo, event, now) do
    event
    |> Ecto.Changeset.change(processed_at: now, processing_error: nil)
    |> repo.update!()
  end

  defp reject!(repo, idempotency_id, reason, event, now) do
    if event do
      event
      |> Ecto.Changeset.change(processed_at: now, processing_error: Atom.to_string(reason))
      |> repo.update!()
    end

    Idempotency.fail!(
      repo,
      idempotency_id,
      reason,
      if(event, do: "payment_provider_event"),
      if(event, do: event.id),
      now
    )

    {:denied, reason}
  end

  defp replay(repo, %Key{
         status: "completed",
         resource_type: "payment_intent",
         resource_id: id
       }) do
    case repo.get(PaymentIntent, id) do
      %PaymentIntent{} = intent -> {:accepted, intent}
      nil -> raise "completed payment termination points to missing intent #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted payment termination response: #{inspect(key)}"
  end

  defp idempotency_key(provider, account, external_event_id) do
    digest = Idempotency.fingerprint({provider.id, account.id, external_event_id})
    "provider-event:" <> Base.encode16(digest, case: :lower)
  end

  defp request_hash(scope, provider, account, external_event_id, payment) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      payment.order_id,
      provider.id,
      account.id,
      external_event_id,
      payment.provider_reference,
      payment.status,
      payment.amount |> Decimal.normalize() |> Decimal.to_string(:normal),
      payment.currency,
      payment.occurred_at,
      payment.payload
    })
  end

  defp terminal_intent({:transitioned, intent, _previous_status}), do: intent
  defp terminal_intent({:reconciled, intent}), do: intent

  defp terminal_previous_status({:transitioned, _intent, previous_status}), do: previous_status

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, intent}}), do: {:ok, intent}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
