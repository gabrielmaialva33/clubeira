defmodule Clubeira.Billing.OrderPlacer do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Billing.CheckoutRequest
  alias Clubeira.Billing.Pricing
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "billing.place_order"
  @replay_reasons %{
    "actor_unavailable" => :actor_unavailable,
    "benefit_package_unavailable" => :benefit_package_unavailable,
    "offering_unavailable" => :offering_unavailable,
    "polo_unavailable" => :polo_unavailable
  }

  @spec place(Scope.t(), map()) ::
          {:ok, Order.t()} | {:error, atom() | Ecto.Changeset.t()}
  def place(%Scope{actor_user_id: nil}, _attributes), do: {:error, :actor_required}

  def place(%Scope{} = scope, attributes) do
    with {:ok, request} <- CheckoutRequest.new(attributes) do
      request_hash = request_hash(scope, request)

      scope
      |> transact_order(request, request_hash)
      |> unwrap_transaction()
    end
  end

  def place(_scope, _attributes), do: {:error, :actor_required}

  defp transact_order(scope, request, request_hash) do
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
          {:new, idempotency_id} -> place_new(repo, scope, request, idempotency_id, now)
          {:replay, key} -> replay(repo, key)
          {:error, reason} -> {:denied, reason}
        end

      {:ok, outcome}
    end)
  end

  defp place_new(repo, scope, request, idempotency_id, now) do
    with :ok <- ensure_actor_active(repo, scope.actor_user_id),
         {:ok, selection} <- Pricing.lock(repo, scope, request, now) do
      order = insert_order!(repo, scope, request, selection.price, now)
      _order_item = insert_order_item!(repo, scope, request, order, selection.price, now)

      record_order_placed!(repo, scope, order, request.product_offering_version_id, now)

      Idempotency.complete!(
        repo,
        idempotency_id,
        "order",
        order.id,
        %{"order_id" => order.id},
        now
      )

      {:accepted, order}
    else
      {:error, reason} -> reject!(repo, idempotency_id, reason, now)
    end
  end

  defp ensure_actor_active(repo, actor_user_id) do
    query = from user in User, where: user.id == ^actor_user_id, lock: "FOR SHARE"

    case repo.one(query) do
      %User{status: "active"} -> :ok
      %User{} -> {:error, :actor_unavailable}
      nil -> {:error, :actor_unavailable}
    end
  end

  defp insert_order!(repo, scope, request, price, now) do
    id = uuid7()
    total = Decimal.mult(price.amount, Decimal.new(request.quantity))

    %Order{
      id: id,
      polo_id: scope.polo_id,
      purchaser_user_id: scope.actor_user_id,
      order_number: order_number(id),
      idempotency_key: request.idempotency_key,
      currency: price.currency,
      subtotal_amount: total,
      discount_amount: Decimal.new(0),
      total_amount: total,
      status: "awaiting_payment",
      placed_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!()
  end

  defp insert_order_item!(repo, scope, request, order, price, now) do
    %OrderItem{
      polo_id: scope.polo_id,
      order_id: order.id,
      product_offering_version_id: request.product_offering_version_id,
      offering_price_id: price.id,
      quantity: request.quantity,
      unit_amount: price.amount,
      total_amount: order.total_amount,
      inserted_at: now
    }
    |> repo.insert!()
  end

  defp record_order_placed!(repo, scope, order, offering_version_id, now) do
    payload = %{
      "order_id" => order.id,
      "product_offering_version_id" => offering_version_id,
      "currency" => order.currency,
      "total_amount" => Decimal.to_string(order.total_amount),
      "placed_at" => DateTime.to_iso8601(order.placed_at)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "order",
      aggregate_id: order.id,
      aggregate_version: 1,
      event_type: "order.placed",
      topic: "billing.orders.placed",
      message_key: order.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "order.placed",
      resource_type: "order",
      resource_id: order.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp reject!(repo, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now)
    {:denied, reason}
  end

  defp replay(repo, %Key{status: "completed", resource_type: "order", resource_id: id}) do
    case repo.get(Order, id) do
      %Order{} = order -> {:accepted, order}
      nil -> raise "completed order idempotency key points to missing resource #{id}"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted order idempotency response: #{inspect(key)}"
  end

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.product_offering_version_id,
      request.offering_price_id,
      request.quantity
    })
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp order_number(id), do: "CLB-" <> (id |> String.replace("-", "") |> String.upcase())

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, order}}), do: {:ok, order}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
