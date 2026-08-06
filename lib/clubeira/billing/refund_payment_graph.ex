defmodule Clubeira.Billing.RefundPaymentGraph do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @type t :: %{
          payment: Payment.t(),
          intent: PaymentIntent.t(),
          order: Order.t(),
          account: MerchantAccount.t(),
          provider: PaymentProvider.t()
        }

  @spec lock_by_payment(module(), Scope.t(), Ecto.UUID.t()) ::
          {:ok, t()} | {:error, :payment_not_found}
  def lock_by_payment(repo, scope, payment_id) do
    query =
      from payment in Payment,
        join: intent in PaymentIntent,
        on:
          intent.id == payment.payment_intent_id and intent.polo_id == payment.polo_id and
            intent.merchant_account_id == payment.merchant_account_id,
        join: order in Order,
        on: order.id == intent.order_id and order.polo_id == intent.polo_id,
        join: assignment in PoloMerchantAccount,
        on:
          assignment.polo_id == payment.polo_id and
            assignment.merchant_account_id == payment.merchant_account_id,
        join: account in MerchantAccount,
        on:
          account.id == payment.merchant_account_id and
            account.payment_provider_id == assignment.payment_provider_id,
        join: provider in PaymentProvider,
        on: provider.id == account.payment_provider_id,
        where: payment.id == ^payment_id and payment.polo_id == ^scope.polo_id,
        lock: "FOR UPDATE",
        select: %{
          payment: payment,
          intent: intent,
          order: order,
          account: account,
          provider: provider
        }

    case repo.one(query) do
      nil -> {:error, :payment_not_found}
      graph -> {:ok, graph}
    end
  end

  @spec lock_by_provider(
          module(),
          Scope.t(),
          PaymentProvider.t(),
          MerchantAccount.t(),
          map()
        ) :: {:ok, t()} | {:error, :refund_reconciliation_mismatch}
  def lock_by_provider(repo, scope, provider, account, provider_refund) do
    query =
      from payment in Payment,
        join: intent in PaymentIntent,
        on:
          intent.id == payment.payment_intent_id and intent.polo_id == payment.polo_id and
            intent.merchant_account_id == payment.merchant_account_id,
        join: order in Order,
        on: order.id == intent.order_id and order.polo_id == intent.polo_id,
        join: assignment in PoloMerchantAccount,
        on:
          assignment.polo_id == payment.polo_id and
            assignment.merchant_account_id == payment.merchant_account_id,
        where: payment.polo_id == ^scope.polo_id,
        where: payment.merchant_account_id == ^account.id,
        where: assignment.payment_provider_id == ^provider.id,
        where: order.id == ^provider_refund.order_id,
        where: intent.provider_reference == ^provider_refund.provider_reference,
        where: payment.provider_reference == ^provider_refund.provider_payment_reference,
        lock: "FOR UPDATE",
        select: %{
          payment: payment,
          intent: intent,
          order: order
        }

    case repo.one(query) do
      nil -> {:error, :refund_reconciliation_mismatch}
      graph -> {:ok, Map.merge(graph, %{account: account, provider: provider})}
    end
  end

  @spec refundable(t()) :: :ok | {:error, :payment_already_refunded | :payment_not_refundable}
  def refundable(%{payment: %Payment{status: "refunded"}}),
    do: {:error, :payment_already_refunded}

  def refundable(%{
        payment: %Payment{
          status: "captured",
          captured_at: %DateTime{},
          currency: "BRL",
          amount: amount
        },
        order: %Order{status: "paid"},
        intent: %PaymentIntent{status: "succeeded", provider_reference: provider_reference}
      })
      when is_binary(provider_reference) do
    if Decimal.positive?(amount), do: :ok, else: {:error, :payment_not_refundable}
  end

  def refundable(_graph), do: {:error, :payment_not_refundable}
end
