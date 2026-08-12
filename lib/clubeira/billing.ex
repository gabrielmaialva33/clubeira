defmodule Clubeira.Billing do
  @moduledoc """
  Provider-neutral sale and consumer payment boundaries.

  `place_order/2` and `start_payment/2` are authenticated member commands;
  `list_orders/2` is their tenant-scoped read model. `settle_payment/2` remains
  the internal capture port and accepts only provider proof authenticated by an
  adapter. Administrative finance reads and full refunds require the polo's
  `manage_billing` capability.
  """

  alias Clubeira.Billing.AccountBillingReader
  alias Clubeira.Billing.BackofficePaymentReader
  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.Billing.BillingAgreementStarter
  alias Clubeira.Billing.OrderPlacer
  alias Clubeira.Billing.OrderReader
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Billing.PaymentSettler
  alias Clubeira.Billing.PaymentStarter
  alias Clubeira.Billing.PaymentWebhookHandler
  alias Clubeira.Billing.RecurringInvoiceSettler
  alias Clubeira.Billing.Refund
  alias Clubeira.Billing.RefundPayment
  alias Clubeira.Billing.RefundSettler
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @spec place_order(Scope.t(), map()) ::
          {:ok, Order.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate place_order(scope, attributes), to: OrderPlacer, as: :place

  @spec list_orders(Scope.t(), map()) ::
          {:ok, %{orders: [map()], page: map()}} | {:error, term()}
  defdelegate list_orders(scope, params), to: OrderReader, as: :list

  @spec list_backoffice_payments(Scope.t(), map()) ::
          {:ok, %{payments: [map()], page: map()}} | {:error, term()}
  defdelegate list_backoffice_payments(scope, params), to: BackofficePaymentReader, as: :list

  @spec get_backoffice_payment(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate get_backoffice_payment(scope, payment_id), to: BackofficePaymentReader, as: :get

  @spec read_account_billing(Scope.t()) ::
          {:ok, %{agreements: [map()]}} | {:error, term()}
  defdelegate read_account_billing(scope), to: AccountBillingReader, as: :read

  @spec start_payment(Scope.t(), map()) ::
          {:ok, %{payment_intent: PaymentIntent.t(), provider: String.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  defdelegate start_payment(scope, attributes), to: PaymentStarter, as: :start

  @spec start_billing_agreement(Scope.t(), map()) ::
          {:ok,
           %{
             billing_agreement: BillingAgreement.t(),
             order_id: Ecto.UUID.t(),
             provider: String.t()
           }}
          | {:error, term()}
  defdelegate start_billing_agreement(scope, attributes),
    to: BillingAgreementStarter,
    as: :start

  @spec refund_payment(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, Refund.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate refund_payment(scope, payment_id, attributes), to: RefundPayment, as: :request

  @spec handle_payment_webhook(String.t(), map()) ::
          {:ok, atom()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate handle_payment_webhook(provider, attributes),
    to: PaymentWebhookHandler,
    as: :handle

  @spec settle_payment(Scope.t(), map()) ::
          {:ok, AccessContract.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate settle_payment(scope, attributes), to: PaymentSettler, as: :settle

  @spec reconcile_refund(
          Scope.t(),
          Clubeira.Billing.PaymentProvider.t(),
          Clubeira.Billing.MerchantAccount.t(),
          Clubeira.Billing.Gateways.refunded_payment()
        ) :: {:ok, Refund.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate reconcile_refund(scope, provider, account, provider_refund),
    to: RefundSettler,
    as: :reconcile

  @spec reconcile_recurring_invoice(
          Scope.t(),
          Clubeira.Billing.PaymentProvider.t(),
          Clubeira.Billing.MerchantAccount.t(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  defdelegate reconcile_recurring_invoice(scope, provider, account, recurring_invoice),
    to: RecurringInvoiceSettler,
    as: :reconcile
end
