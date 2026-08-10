defmodule Clubeira.Billing.Gateways.Adapter do
  @moduledoc """
  Contract implemented by payment service provider adapters.

  Adapters own provider credentials, HTTP calls, webhook authentication and
  payload normalization. The billing core receives only the normalized types
  declared by `Clubeira.Billing.Gateways`.
  """

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.MerchantAccount

  @callback create_payment(MerchantAccount.t(), String.t(), Gateways.payment_request()) ::
              {:ok, Gateways.created_payment()} | {:error, atom()}

  @callback create_subscription(MerchantAccount.t(), Gateways.subscription_request()) ::
              {:ok, Gateways.created_subscription()} | {:error, atom()}

  @callback refund_payment(
              MerchantAccount.t(),
              String.t(),
              Gateways.refund_request()
            ) :: {:ok, Gateways.refunded_payment()} | {:error, atom()}

  @callback authenticate_webhook(
              MerchantAccount.t(),
              String.t(),
              String.t(),
              String.t()
            ) :: :ok | {:error, atom()}

  @callback verify_webhook(MerchantAccount.t(), Gateways.webhook_envelope()) ::
              {:ok, Gateways.webhook_event()} | {:error, atom()}

  @callback fetch_payment(MerchantAccount.t(), String.t()) ::
              {:ok,
               :pending
               | {:terminal, Gateways.terminal_payment()}
               | {:refunded, Gateways.refunded_payment()}
               | Gateways.captured_payment()}
              | {:error, atom()}

  @callback fetch_recurring_invoice(MerchantAccount.t(), String.t()) ::
              {:ok, Gateways.recurring_invoice() | Gateways.platform_invoice()}
              | {:error, atom()}

  @callback fetch_chargeback(MerchantAccount.t(), String.t()) ::
              {:ok, Gateways.chargeback()} | {:error, atom()}
end
