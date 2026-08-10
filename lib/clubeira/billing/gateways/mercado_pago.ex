defmodule Clubeira.Billing.Gateways.MercadoPago do
  @moduledoc """
  Mercado Pago adapter for the provider-neutral billing gateway.

  Provider payloads and credentials terminate in the capability modules under
  this namespace. The billing core receives only normalized gateway values.
  """

  @behaviour Clubeira.Billing.Gateways.Adapter

  alias Clubeira.Billing.Gateways.MercadoPago.Chargebacks
  alias Clubeira.Billing.Gateways.MercadoPago.Payments
  alias Clubeira.Billing.Gateways.MercadoPago.Refunds
  alias Clubeira.Billing.Gateways.MercadoPago.Subscriptions
  alias Clubeira.Billing.Gateways.MercadoPago.Webhook
  alias Clubeira.Billing.MerchantAccount

  @impl true
  def create_payment(%MerchantAccount{} = account, "pix", request),
    do: Payments.create(account, request)

  def create_payment(%MerchantAccount{}, _payment_method, _request),
    do: {:error, :payment_gateway_unsupported}

  @impl true
  def create_subscription(%MerchantAccount{} = account, request),
    do: Subscriptions.create(account, request)

  @impl true
  def refund_payment(%MerchantAccount{} = account, provider_reference, request),
    do: Refunds.refund(account, provider_reference, request)

  @impl true
  def verify_webhook(%MerchantAccount{} = account, envelope),
    do: Webhook.verify(account, envelope)

  @impl true
  def fetch_payment(%MerchantAccount{} = account, provider_reference),
    do: Payments.fetch(account, provider_reference)

  @impl true
  def fetch_recurring_invoice(%MerchantAccount{} = account, provider_reference),
    do: Subscriptions.fetch_invoice(account, provider_reference)

  @impl true
  def fetch_chargeback(%MerchantAccount{} = account, provider_reference),
    do: Chargebacks.fetch(account, provider_reference)
end
