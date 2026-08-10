defmodule Clubeira.Platform.SubscriptionStarter do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PoloSubscription
  alias Clubeira.Platform.Price
  alias Clubeira.Platform.SubscriptionStartRequest
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @provider_code "mercado_pago"

  @type result :: %{
          provider: String.t(),
          subscription: PoloSubscription.t()
        }

  @spec start(Scope.t(), map()) :: {:ok, result()} | {:error, term()}
  def start(%Scope{actor_user_id: nil}, _attributes), do: {:error, :billing_admin_required}

  def start(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- SubscriptionStartRequest.new(attributes),
         {:ok, reservation} <- reserve(scope, request) do
      start_reserved(scope, reservation)
    end
  end

  def start(_scope, _attributes), do: {:error, :billing_admin_required}

  defp reserve(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- lock_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_billing, now),
           {:ok, graph} <- lock_price_graph(repo, request.platform_price_id, now),
           :ok <- validate_price_graph(graph),
           {:ok, purchaser} <- lock_purchaser(repo, scope.actor_user_id),
           {:ok, account, provider} <- lock_platform_account(repo),
           {:ok, subscription} <-
             reserve_subscription(repo, scope, graph, account, request, now) do
        {:ok,
         graph
         |> Map.merge(%{
           account: account,
           provider: provider,
           purchaser: purchaser,
           request: request,
           subscription: subscription
         })}
      end
    end)
  end

  defp start_reserved(_scope, %{subscription: subscription, provider: provider})
       when is_binary(subscription.provider_reference) do
    {:ok, %{provider: provider.code, subscription: subscription}}
  end

  defp start_reserved(scope, reservation) do
    request = %{
      amount: reservation.price.amount,
      back_url: subscription_back_url(reservation.provider.code),
      currency: reservation.price.currency,
      external_reference: "platform:#{scope.polo_id}:#{reservation.subscription.id}",
      idempotency_key: reservation.subscription.id,
      interval: recurring_interval(reservation.price),
      order_id: reservation.subscription.id,
      payer_email: reservation.purchaser.email,
      polo_id: scope.polo_id,
      reason: reservation.version.name
    }

    with {:ok, provider_subscription} <-
           Gateways.create_subscription(reservation.provider.code, reservation.account, request),
         {:ok, subscription} <- finalize(scope, reservation, provider_subscription) do
      {:ok, %{provider: reservation.provider.code, subscription: subscription}}
    end
  end

  defp lock_active_polo(repo, polo_id) do
    case repo.one(from(polo in Polo, where: polo.id == ^polo_id, lock: "FOR UPDATE")) do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp lock_price_graph(repo, price_id, now) do
    query =
      from price in Price,
        join: version in PlanVersion,
        on: version.id == price.platform_plan_version_id,
        join: plan in Plan,
        on: plan.id == version.platform_plan_id,
        where: price.id == ^price_id,
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            price.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: %{price: price, version: version, plan: plan}

    case repo.one(query) do
      nil -> {:error, :platform_price_not_found}
      graph -> {:ok, graph}
    end
  end

  defp validate_price_graph(graph) do
    cond do
      graph.plan.status != "active" or graph.version.status != "published" ->
        {:error, :platform_price_not_found}

      graph.price.currency != "BRL" ->
        {:error, :platform_subscription_unsupported}

      not Decimal.positive?(graph.price.amount) ->
        {:error, :platform_subscription_unsupported}

      graph.price.billing_interval_unit not in ["month", "year"] ->
        {:error, :platform_subscription_unsupported}

      true ->
        :ok
    end
  end

  defp lock_purchaser(repo, user_id) do
    case repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR SHARE")) do
      %User{status: "active"} = user -> {:ok, user}
      _missing_or_inactive -> {:error, :billing_admin_required}
    end
  end

  defp lock_platform_account(repo) do
    with {:ok, merchant_account_id} <- configured_merchant_account_id() do
      query =
        from account in MerchantAccount,
          join: provider in PaymentProvider,
          on: provider.id == account.payment_provider_id,
          where: account.id == ^merchant_account_id,
          where: account.kind == "platform" and account.status == "active",
          where: provider.status == "active" and provider.code == @provider_code,
          lock: "FOR SHARE",
          select: {account, provider}

      case repo.one(query) do
        {%MerchantAccount{} = account, %PaymentProvider{} = provider} ->
          {:ok, account, provider}

        nil ->
          {:error, :payment_gateway_not_configured}
      end
    end
  end

  defp configured_merchant_account_id do
    configured =
      :clubeira
      |> Application.get_env(:platform_billing, [])
      |> Keyword.get(:merchant_account_id)

    case Ecto.UUID.cast(configured) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :payment_gateway_not_configured}
    end
  end

  defp reserve_subscription(repo, scope, graph, account, request, now) do
    request_sha256 =
      Idempotency.fingerprint({
        1,
        scope.polo_id,
        scope.actor_user_id,
        request.platform_price_id
      })

    existing =
      repo.one(
        from(subscription in PoloSubscription,
          where:
            subscription.polo_id == ^scope.polo_id and
              subscription.requested_by_user_id == ^scope.actor_user_id and
              subscription.idempotency_key == ^request.idempotency_key,
          lock: "FOR UPDATE"
        )
      )

    case existing do
      %PoloSubscription{} = subscription ->
        if :crypto.hash_equals(subscription.request_sha256, request_sha256),
          do: {:ok, subscription},
          else: {:error, :idempotency_conflict}

      nil ->
        if current_subscription?(repo, scope) do
          {:error, :platform_subscription_already_active}
        else
          insert_subscription(repo, scope, graph, account, request, request_sha256, now)
        end
    end
  end

  defp current_subscription?(repo, scope) do
    repo.exists?(
      from(subscription in PoloSubscription,
        where:
          subscription.polo_id == ^scope.polo_id and
            subscription.status in ["pending", "active", "past_due", "suspended"]
      )
    )
  end

  defp insert_subscription(repo, scope, graph, account, request, request_sha256, now) do
    %PoloSubscription{
      polo_id: scope.polo_id,
      platform_plan_version_id: graph.version.id,
      platform_price_id: graph.price.id,
      merchant_account_id: account.id,
      requested_by_user_id: scope.actor_user_id,
      idempotency_key: request.idempotency_key,
      request_sha256: request_sha256,
      status: "pending",
      next_action: %{},
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:polo_id,
      name: :polo_platform_subscriptions_current_uidx
    )
    |> Ecto.Changeset.unique_constraint(:idempotency_key,
      name: :polo_platform_subscriptions_actor_idempotency_uidx
    )
    |> repo.insert()
  end

  defp finalize(scope, reservation, provider_subscription) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      subscription =
        repo.one!(
          from(subscription in PoloSubscription,
            where:
              subscription.id == ^reservation.subscription.id and
                subscription.polo_id == ^scope.polo_id,
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_binary(subscription.provider_reference) ->
          {:ok, subscription}

        not Decimal.equal?(provider_subscription.amount, reservation.price.amount) ->
          {:error, :payment_gateway_invalid_response}

        true ->
          update_from_provider(repo, scope, subscription, provider_subscription, now)
      end
    end)
  end

  defp update_from_provider(repo, scope, subscription, provider_subscription, now) do
    updated =
      subscription
      |> Ecto.Changeset.change(
        provider_reference: provider_subscription.provider_reference,
        status: provider_subscription.status,
        next_charge_at: provider_subscription.next_charge_at,
        next_action: provider_subscription.next_action,
        updated_at: now
      )
      |> Ecto.Changeset.unique_constraint(:provider_reference,
        name: :polo_platform_subscriptions_provider_uidx
      )
      |> repo.update!()

    payload = %{
      "polo_platform_subscription_id" => updated.id,
      "platform_plan_version_id" => updated.platform_plan_version_id,
      "platform_price_id" => updated.platform_price_id,
      "status" => updated.status,
      "next_charge_at" => datetime(updated.next_charge_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "polo_platform_subscription",
      aggregate_id: updated.id,
      aggregate_version: 1,
      event_type: "platform_subscription.started",
      topic: "platform.billing.subscriptions.started",
      message_key: updated.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "platform_subscription.started",
      resource_type: "polo_platform_subscription",
      resource_id: updated.id,
      metadata: payload,
      occurred_at: now
    })

    {:ok, updated}
  end

  defp recurring_interval(%Price{billing_interval_unit: "month", billing_interval_count: count}),
    do: %{frequency: count, type: "months"}

  defp recurring_interval(%Price{billing_interval_unit: "year", billing_interval_count: count}),
    do: %{frequency: count * 12, type: "months"}

  defp subscription_back_url(provider_code) do
    case Application.get_env(:clubeira, Clubeira.Billing.Gateways.MercadoPago, [])[
           :subscription_back_url
         ] do
      value when is_binary(value) -> value
      _missing when provider_code == @provider_code -> nil
    end
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
