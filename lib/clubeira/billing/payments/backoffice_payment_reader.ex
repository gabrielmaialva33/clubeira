defmodule Clubeira.Billing.BackofficePaymentReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.Chargeback
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.Refund
  alias Clubeira.Polos.Authorization
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @default_page_limit 20
  @maximum_page_limit 100
  @payment_statuses ~w(authorized captured failed cancelled refunded charged_back)

  @spec list(Scope.t(), map()) ::
          {:ok, %{payments: [map()], page: map()}}
          | {:error,
             :billing_admin_required
             | :invalid_order_number
             | :invalid_pagination
             | :invalid_payment_status
             | term()}
  def list(%Scope{actor_user_id: nil}, _params), do: {:error, :billing_admin_required}

  def list(%Scope{} = scope, params) when is_map(params) do
    with {:ok, pagination} <- parse_pagination(params),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, order_number} <- parse_order_number(Map.get(params, "order_number")) do
      Repo.transact_in_polo(
        scope,
        &list_authorized(&1, scope, status, order_number, pagination)
      )
    end
  end

  def list(_scope, _params), do: {:error, :billing_admin_required}

  @spec get(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :billing_admin_required | :payment_not_found | term()}
  def get(%Scope{actor_user_id: nil}, _payment_id), do: {:error, :billing_admin_required}

  def get(%Scope{} = scope, payment_id) do
    with {:ok, payment_id} <- cast_payment_id(payment_id) do
      Repo.transact_in_polo(scope, &get_authorized(&1, scope, payment_id))
    end
  end

  def get(_scope, _payment_id), do: {:error, :billing_admin_required}

  defp list_authorized(repo, scope, status, order_number, pagination) do
    with :ok <- Authorization.authorize(repo, scope, :manage_billing, transaction_time(repo)) do
      {:ok, payment_page(repo, scope, status, order_number, pagination)}
    end
  end

  defp get_authorized(repo, scope, payment_id) do
    with :ok <- Authorization.authorize(repo, scope, :manage_billing, transaction_time(repo)) do
      payment =
        scope
        |> base_payments_query()
        |> where([payment], payment.id == ^payment_id)
        |> select_payment()
        |> repo.one()

      if payment,
        do: {:ok, payment_data(payment)},
        else: {:error, :payment_not_found}
    end
  end

  defp payment_page(repo, scope, status, order_number, pagination) do
    query_limit = pagination.limit + 1

    rows =
      scope
      |> base_payments_query()
      |> with_status(status)
      |> with_order_number(order_number)
      |> after_payment(pagination.after)
      |> order_by([payment], desc: payment.inserted_at, desc: payment.id)
      |> select_payment()
      |> limit(^query_limit)
      |> repo.all()

    {page_rows, overflow} = Enum.split(rows, pagination.limit)
    has_more = overflow != []

    %{
      payments: Enum.map(page_rows, &payment_data/1),
      page: %{
        limit: pagination.limit,
        has_more: has_more,
        next_cursor: next_cursor(page_rows, has_more)
      }
    }
  end

  defp base_payments_query(scope) do
    Payment
    |> join(:inner, [payment], intent in PaymentIntent,
      on:
        intent.id == payment.payment_intent_id and
          intent.polo_id == payment.polo_id and
          intent.merchant_account_id == payment.merchant_account_id
    )
    |> join(:inner, [_payment, intent], order in Order,
      on: order.id == intent.order_id and order.polo_id == intent.polo_id
    )
    |> join(:inner, [payment, _intent, _order], account in MerchantAccount,
      on: account.id == payment.merchant_account_id
    )
    |> join(:inner, [_payment, _intent, _order, account], provider in PaymentProvider,
      on: provider.id == account.payment_provider_id
    )
    |> join_latest_refund(scope.polo_id)
    |> join_latest_chargeback(scope.polo_id)
    |> where([payment], payment.polo_id == ^scope.polo_id)
  end

  defp join_latest_refund(query, polo_id) do
    latest_refunds =
      from refund in Refund,
        where: refund.polo_id == ^polo_id,
        distinct: [refund.payment_id],
        order_by: [asc: refund.payment_id, desc: refund.inserted_at, desc: refund.id],
        select: %{
          id: refund.id,
          payment_id: refund.payment_id,
          amount: refund.amount,
          status: refund.status,
          requested_at: refund.requested_at,
          completed_at: refund.completed_at
        }

    join(query, :left, [payment], refund in subquery(latest_refunds),
      on: refund.payment_id == payment.id
    )
  end

  defp join_latest_chargeback(query, polo_id) do
    latest_chargebacks =
      from chargeback in Chargeback,
        where: chargeback.polo_id == ^polo_id,
        distinct: [chargeback.payment_id],
        order_by: [
          asc: chargeback.payment_id,
          desc: chargeback.updated_at,
          desc: chargeback.id
        ],
        select: %{
          id: chargeback.id,
          payment_id: chargeback.payment_id,
          amount: chargeback.amount,
          status: chargeback.status,
          opened_at: chargeback.opened_at,
          closed_at: chargeback.closed_at
        }

    join(query, :left, [payment], chargeback in subquery(latest_chargebacks),
      on: chargeback.payment_id == payment.id
    )
  end

  defp select_payment(query) do
    select(
      query,
      [payment, intent, order, _account, provider, refund, chargeback],
      %{
        id: payment.id,
        status: payment.status,
        amount: payment.amount,
        currency: payment.currency,
        payment_method: intent.payment_method,
        provider_code: provider.code,
        captured_at: payment.captured_at,
        refunded_at: payment.refunded_at,
        recorded_at: payment.inserted_at,
        order_id: order.id,
        order_number: order.order_number,
        order_status: order.status,
        purchaser_user_id: order.purchaser_user_id,
        placed_at: order.placed_at,
        refund_id: refund.id,
        refund_status: refund.status,
        refund_amount: refund.amount,
        refund_requested_at: refund.requested_at,
        refund_completed_at: refund.completed_at,
        chargeback_id: chargeback.id,
        chargeback_status: chargeback.status,
        chargeback_amount: chargeback.amount,
        chargeback_opened_at: chargeback.opened_at,
        chargeback_closed_at: chargeback.closed_at
      }
    )
  end

  defp payment_data(row) do
    %{
      id: row.id,
      status: row.status,
      amount: row.amount,
      currency: row.currency,
      payment_method: row.payment_method,
      provider_code: row.provider_code,
      captured_at: row.captured_at,
      refunded_at: row.refunded_at,
      recorded_at: row.recorded_at,
      order: %{
        id: row.order_id,
        order_number: row.order_number,
        status: row.order_status,
        purchaser_user_id: row.purchaser_user_id,
        placed_at: row.placed_at
      },
      refund: refund_data(row),
      chargeback: chargeback_data(row)
    }
  end

  defp refund_data(%{refund_id: nil}), do: nil

  defp refund_data(row) do
    %{
      id: row.refund_id,
      status: row.refund_status,
      amount: row.refund_amount,
      requested_at: row.refund_requested_at,
      completed_at: row.refund_completed_at
    }
  end

  defp chargeback_data(%{chargeback_id: nil}), do: nil

  defp chargeback_data(row) do
    %{
      id: row.chargeback_id,
      status: row.chargeback_status,
      amount: row.chargeback_amount,
      opened_at: row.chargeback_opened_at,
      closed_at: row.chargeback_closed_at
    }
  end

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: where(query, [payment], payment.status == ^status)

  defp with_order_number(query, nil), do: query

  defp with_order_number(query, order_number) do
    where(query, [_payment, _intent, order], order.order_number == ^order_number)
  end

  defp after_payment(query, nil), do: query

  defp after_payment(query, %{recorded_at: recorded_at, id: id}) do
    where(
      query,
      [payment],
      payment.inserted_at < ^recorded_at or
        (payment.inserted_at == ^recorded_at and payment.id < ^id)
    )
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, after_payment} <- parse_cursor(Map.get(params, "after")) do
      {:ok, %{limit: limit, after: after_payment}}
    else
      :error -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_page_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@maximum_page_limit -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp parse_limit(_limit), do: :error

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, <<unix_microsecond::signed-64, payment_id_binary::binary-size(16)>>} <-
           Base.url_decode64(cursor, padding: false),
         {:ok, recorded_at} <- DateTime.from_unix(unix_microsecond, :microsecond),
         {:ok, payment_id} <- Ecto.UUID.load(payment_id_binary) do
      {:ok, %{recorded_at: recorded_at, id: payment_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  defp next_cursor(_payments, false), do: nil

  defp next_cursor(payments, true) do
    %{recorded_at: recorded_at, id: id} = List.last(payments)
    unix_microsecond = DateTime.to_unix(recorded_at, :microsecond)

    <<unix_microsecond::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @payment_statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :invalid_payment_status}

  defp parse_order_number(nil), do: {:ok, nil}

  defp parse_order_number(order_number) when is_binary(order_number) do
    normalized = String.trim(order_number)

    if byte_size(normalized) in 1..128 do
      {:ok, normalized}
    else
      {:error, :invalid_order_number}
    end
  end

  defp parse_order_number(_order_number), do: {:error, :invalid_order_number}

  defp cast_payment_id(payment_id) do
    case Ecto.UUID.cast(payment_id) do
      {:ok, payment_id} -> {:ok, payment_id}
      :error -> {:error, :payment_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
    now
  end
end
