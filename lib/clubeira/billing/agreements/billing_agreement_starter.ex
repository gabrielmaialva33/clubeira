defmodule Clubeira.Billing.BillingAgreementStarter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.Billing.BillingAgreementStartRequest
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @provider_code "mercado_pago"

  @type result :: %{
          billing_agreement: BillingAgreement.t(),
          order_id: Ecto.UUID.t(),
          provider: String.t()
        }

  @spec start(Scope.t(), map()) :: {:ok, result()} | {:error, term()}
  def start(%Scope{actor_user_id: nil}, _attributes), do: {:error, :actor_required}

  def start(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- BillingAgreementStartRequest.new(attributes),
         {:ok, reservation} <- reserve(scope, request) do
      start_reserved(scope, reservation)
    end
  end

  def start(_scope, _attributes), do: {:error, :actor_required}

  defp reserve(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, graph} <- lock_order_graph(repo, scope, request.order_id),
           :ok <- validate_order_graph(graph),
           {:ok, account, provider} <- lock_gateway_account(repo, scope, now),
           {:ok, agreement} <- reserve_agreement(repo, scope, graph, account, request, now) do
        {:ok,
         graph
         |> Map.merge(%{account: account, provider: provider, agreement: agreement})
         |> Map.put(:request, request)}
      end
    end)
  end

  defp start_reserved(_scope, %{agreement: agreement, order: order, provider: provider})
       when is_binary(agreement.provider_reference) do
    {:ok, %{billing_agreement: agreement, order_id: order.id, provider: provider.code}}
  end

  defp start_reserved(scope, reservation) do
    request = %{
      amount: reservation.order.total_amount,
      back_url: subscription_back_url(reservation.provider.code),
      currency: reservation.order.currency,
      external_reference: "#{scope.polo_id}_#{reservation.order.id}",
      idempotency_key: reservation.agreement.id,
      interval: recurring_interval(reservation.offering_version),
      order_id: reservation.order.id,
      payer_email: reservation.purchaser.email,
      polo_id: scope.polo_id,
      reason: reservation.offering_version.name
    }

    with {:ok, provider_agreement} <-
           Gateways.create_subscription(
             reservation.provider.code,
             reservation.account,
             request
           ),
         {:ok, agreement} <- finalize(scope, reservation, provider_agreement) do
      {:ok,
       %{
         billing_agreement: agreement,
         order_id: reservation.order.id,
         provider: reservation.provider.code
       }}
    end
  end

  defp lock_order_graph(repo, scope, order_id) do
    query =
      from order in Order,
        join: purchaser in User,
        on: purchaser.id == order.purchaser_user_id,
        join: item in OrderItem,
        on: item.order_id == order.id and item.polo_id == order.polo_id,
        join: version in ProductOfferingVersion,
        on:
          version.id == item.product_offering_version_id and
            version.polo_id == item.polo_id,
        join: price in OfferingPrice,
        on:
          price.id == item.offering_price_id and price.polo_id == item.polo_id and
            price.product_offering_version_id == item.product_offering_version_id,
        where:
          order.id == ^order_id and order.polo_id == ^scope.polo_id and
            order.purchaser_user_id == ^scope.actor_user_id,
        lock: "FOR UPDATE",
        select: %{
          order: order,
          purchaser: purchaser,
          order_item: item,
          offering_version: version,
          price: price
        }

    case repo.all(query) do
      [graph] -> {:ok, graph}
      _missing_or_invalid_shape -> {:error, :order_not_found}
    end
  end

  defp validate_order_graph(graph) do
    cond do
      graph.purchaser.status != "active" ->
        {:error, :order_not_found}

      graph.order.status not in ["pending", "awaiting_payment"] ->
        {:error, :order_not_payable}

      graph.order.currency != "BRL" ->
        {:error, :automatic_renewal_unsupported}

      not Decimal.positive?(graph.order.total_amount) ->
        {:error, :order_not_payable}

      graph.offering_version.renewal_policy != "automatic" ->
        {:error, :automatic_renewal_not_enabled}

      graph.price.billing_model != "subscription" ->
        {:error, :automatic_renewal_unsupported}

      not supported_interval?(graph.offering_version) ->
        {:error, :automatic_renewal_unsupported}

      true ->
        :ok
    end
  end

  defp lock_gateway_account(repo, scope, now) do
    query =
      from assignment in PoloMerchantAccount,
        join: account in MerchantAccount,
        on: account.id == assignment.merchant_account_id,
        join: provider in PaymentProvider,
        on: provider.id == assignment.payment_provider_id,
        where: assignment.polo_id == ^scope.polo_id,
        where: assignment.role == "primary",
        where: account.payment_provider_id == provider.id,
        where: account.kind == "consumer" and account.status == "active",
        where: provider.status == "active" and provider.code == @provider_code,
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            assignment.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        order_by: [asc: account.id],
        limit: 1,
        lock: "FOR SHARE",
        select: {account, provider}

    case repo.one(query) do
      {%MerchantAccount{} = account, %PaymentProvider{} = provider} ->
        {:ok, account, provider}

      nil ->
        {:error, :payment_gateway_unavailable}
    end
  end

  defp reserve_agreement(repo, scope, graph, account, request, now) do
    request_hash = request_hash(scope, graph, request)

    existing =
      BillingAgreement
      |> where(
        [agreement],
        agreement.polo_id == ^scope.polo_id and agreement.user_id == ^scope.actor_user_id and
          agreement.idempotency_key == ^request.idempotency_key
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case existing do
      %BillingAgreement{} = agreement ->
        if :crypto.hash_equals(agreement.request_sha256, request_hash),
          do: {:ok, agreement},
          else: {:error, :idempotency_conflict}

      nil ->
        insert_agreement(repo, scope, graph, account, request, request_hash, now)
    end
  end

  defp insert_agreement(repo, scope, graph, account, request, request_hash, now) do
    %BillingAgreement{
      polo_id: scope.polo_id,
      user_id: scope.actor_user_id,
      product_offering_version_id: graph.offering_version.id,
      order_item_id: graph.order_item.id,
      merchant_account_id: account.id,
      idempotency_key: request.idempotency_key,
      request_sha256: request_hash,
      status: "pending",
      next_action: %{},
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:order_item_id,
      name: :billing_agreements_order_item_uidx
    )
    |> Ecto.Changeset.unique_constraint(:idempotency_key,
      name: :billing_agreements_actor_idempotency_uidx
    )
    |> repo.insert(mode: :savepoint)
    |> case do
      {:ok, agreement} -> {:ok, agreement}
      {:error, changeset} -> classify_reservation_error(changeset)
    end
  end

  defp classify_reservation_error(changeset) do
    if constraint_error?(changeset, "billing_agreements_order_item_uidx"),
      do: {:error, :billing_agreement_already_started},
      else: {:error, changeset}
  end

  defp finalize(scope, reservation, provider_agreement) do
    Repo.transact_in_polo(scope, fn repo ->
      agreement =
        BillingAgreement
        |> where(
          [agreement],
          agreement.id == ^reservation.agreement.id and agreement.polo_id == ^scope.polo_id and
            agreement.user_id == ^scope.actor_user_id
        )
        |> lock("FOR UPDATE")
        |> repo.one!()

      cond do
        is_binary(agreement.provider_reference) ->
          {:ok, agreement}

        not Decimal.equal?(provider_agreement.amount, reservation.order.total_amount) ->
          {:error, :payment_gateway_invalid_response}

        true ->
          update_from_provider(repo, scope, agreement, provider_agreement)
      end
    end)
  end

  defp update_from_provider(repo, scope, agreement, provider_agreement) do
    now = transaction_time(repo)

    updated =
      agreement
      |> Ecto.Changeset.change(
        provider_reference: provider_agreement.provider_reference,
        status: provider_agreement.status,
        next_charge_at: provider_agreement.next_charge_at,
        next_action: provider_agreement.next_action,
        updated_at: now
      )
      |> Ecto.Changeset.unique_constraint(:provider_reference,
        name: :billing_agreements_provider_reference_uidx
      )
      |> repo.update!()

    payload = %{
      "billing_agreement_id" => updated.id,
      "order_item_id" => updated.order_item_id,
      "product_offering_version_id" => updated.product_offering_version_id,
      "status" => updated.status,
      "next_charge_at" => datetime(updated.next_charge_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "billing_agreement",
      aggregate_id: updated.id,
      aggregate_version: 1,
      event_type: "billing_agreement.started",
      topic: "billing.agreements.started",
      message_key: updated.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "billing_agreement.started",
      resource_type: "billing_agreement",
      resource_id: updated.id,
      metadata: payload,
      occurred_at: now
    })

    {:ok, updated}
  end

  defp supported_interval?(%ProductOfferingVersion{
         cycle_interval_unit: unit,
         cycle_interval_count: count
       })
       when unit in ["day", "month", "year"] and is_integer(count) and count > 0,
       do: true

  defp supported_interval?(_version), do: false

  defp recurring_interval(%ProductOfferingVersion{
         cycle_interval_unit: "day",
         cycle_interval_count: count
       }),
       do: %{frequency: count, type: "days"}

  defp recurring_interval(%ProductOfferingVersion{
         cycle_interval_unit: "month",
         cycle_interval_count: count
       }),
       do: %{frequency: count, type: "months"}

  defp recurring_interval(%ProductOfferingVersion{
         cycle_interval_unit: "year",
         cycle_interval_count: count
       }),
       do: %{frequency: count * 12, type: "months"}

  defp subscription_back_url(provider_code) do
    case Application.get_env(:clubeira, Clubeira.Billing.Gateways.MercadoPago, [])[
           :subscription_back_url
         ] do
      value when is_binary(value) -> value
      _missing when provider_code == "mercado_pago" -> nil
    end
  end

  defp request_hash(scope, graph, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.order_id,
      graph.order_item.id,
      graph.offering_version.id,
      graph.order.currency,
      graph.order.total_amount |> Decimal.normalize() |> Decimal.to_string(:normal)
    })
  end

  defp constraint_error?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      to_string(options[:constraint_name]) == name
    end)
  end

  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
