defmodule Clubeira.Billing.Gateways do
  @moduledoc false

  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.MerchantAccount

  @type payment_request :: %{
          required(:amount) => Decimal.t(),
          required(:currency) => String.t(),
          required(:idempotency_key) => String.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:payer_email) => String.t()
        }

  @type created_payment :: %{
          required(:amount) => Decimal.t(),
          required(:next_action) => map(),
          required(:provider_payment_reference) => String.t(),
          required(:provider_reference) => String.t()
        }

  @type subscription_request :: %{
          required(:amount) => Decimal.t(),
          required(:back_url) => String.t(),
          required(:currency) => String.t(),
          required(:external_reference) => String.t(),
          required(:idempotency_key) => Ecto.UUID.t(),
          required(:interval) => %{
            required(:frequency) => pos_integer(),
            required(:type) => String.t()
          },
          required(:order_id) => Ecto.UUID.t(),
          required(:payer_email) => String.t(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:reason) => String.t()
        }

  @type created_subscription :: %{
          required(:amount) => Decimal.t(),
          required(:next_action) => map(),
          required(:next_charge_at) => DateTime.t() | nil,
          required(:provider_reference) => String.t(),
          required(:status) => String.t()
        }

  @type recurring_invoice :: %{
          required(:billing_scope) => :consumer,
          required(:amount) => Decimal.t(),
          required(:billing_agreement_reference) => String.t(),
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:payload) => map(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_invoice_reference) => String.t(),
          required(:provider_payment_reference) => String.t(),
          required(:status) => String.t()
        }

  @type platform_invoice :: %{
          required(:amount) => Decimal.t(),
          required(:billing_scope) => :platform,
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:payload) => map(),
          required(:platform_subscription_id) => Ecto.UUID.t(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_invoice_reference) => String.t(),
          required(:provider_payment_reference) => String.t(),
          required(:provider_subscription_reference) => String.t(),
          required(:status) => String.t()
        }

  @type chargeback :: %{
          required(:amount) => Decimal.t(),
          required(:closed_at) => DateTime.t() | nil,
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:opened_at) => DateTime.t(),
          required(:payload) => map(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_payment_reference) => String.t(),
          required(:provider_reference) => String.t(),
          required(:reason_code) => String.t() | nil,
          required(:status) => String.t()
        }

  @type captured_payment :: %{
          required(:amount) => Decimal.t(),
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:payload) => map(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_payment_reference) => String.t(),
          required(:provider_reference) => String.t()
        }

  @type terminal_payment :: %{
          required(:amount) => Decimal.t(),
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:payload) => map(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_reference) => String.t(),
          required(:status) => String.t()
        }

  @type refund_request :: %{
          required(:amount) => Decimal.t(),
          required(:currency) => String.t(),
          required(:idempotency_key) => Ecto.UUID.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_payment_reference) => String.t()
        }

  @type refunded_payment :: %{
          required(:amount) => Decimal.t(),
          required(:currency) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:order_id) => Ecto.UUID.t(),
          required(:payload) => map(),
          required(:polo_id) => Ecto.UUID.t(),
          required(:provider_payment_reference) => String.t(),
          required(:provider_reference) => String.t(),
          required(:provider_refund_reference) => String.t()
        }

  @spec create_payment(String.t(), MerchantAccount.t(), String.t(), payment_request()) ::
          {:ok, created_payment()} | {:error, atom()}
  def create_payment("mercado_pago", %MerchantAccount{} = account, "pix", request) do
    MercadoPago.create_pix(account, request)
  end

  def create_payment(_provider, %MerchantAccount{}, _payment_method, _request) do
    {:error, :payment_gateway_unsupported}
  end

  @spec create_subscription(String.t(), MerchantAccount.t(), subscription_request()) ::
          {:ok, created_subscription()} | {:error, atom()}
  def create_subscription("mercado_pago", %MerchantAccount{} = account, request) do
    MercadoPago.create_subscription(account, request)
  end

  def create_subscription(_provider, %MerchantAccount{}, _request) do
    {:error, :payment_gateway_unsupported}
  end

  @spec refund_payment(String.t(), MerchantAccount.t(), String.t(), refund_request()) ::
          {:ok, refunded_payment()} | {:error, atom()}
  def refund_payment("mercado_pago", %MerchantAccount{} = account, provider_reference, request) do
    MercadoPago.refund_order(account, provider_reference, request)
  end

  def refund_payment(_provider, %MerchantAccount{}, _provider_reference, _request) do
    {:error, :payment_gateway_unsupported}
  end

  @spec authenticate_webhook(
          String.t(),
          MerchantAccount.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | {:error, atom()}
  def authenticate_webhook(
        "mercado_pago",
        %MerchantAccount{} = account,
        data_id,
        request_id,
        signature
      ) do
    MercadoPago.authenticate_webhook(account, data_id, request_id, signature)
  end

  def authenticate_webhook(_provider, %MerchantAccount{}, _data_id, _request_id, _signature) do
    {:error, :payment_gateway_unsupported}
  end

  @spec fetch_payment(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok,
           :pending
           | {:terminal, terminal_payment()}
           | {:refunded, refunded_payment()}
           | captured_payment()}
          | {:error, atom()}
  def fetch_payment("mercado_pago", %MerchantAccount{} = account, provider_reference) do
    MercadoPago.fetch_order(account, provider_reference)
  end

  def fetch_payment(_provider, %MerchantAccount{}, _provider_reference) do
    {:error, :payment_gateway_unsupported}
  end

  @spec fetch_recurring_invoice(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok, recurring_invoice() | platform_invoice()} | {:error, atom()}
  def fetch_recurring_invoice("mercado_pago", %MerchantAccount{} = account, reference) do
    MercadoPago.fetch_recurring_invoice(account, reference)
  end

  def fetch_recurring_invoice(_provider, %MerchantAccount{}, _reference) do
    {:error, :payment_gateway_unsupported}
  end

  @spec fetch_chargeback(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok, chargeback()} | {:error, atom()}
  def fetch_chargeback("mercado_pago", %MerchantAccount{} = account, reference) do
    MercadoPago.fetch_chargeback(account, reference)
  end

  def fetch_chargeback(_provider, %MerchantAccount{}, _reference) do
    {:error, :payment_gateway_unsupported}
  end
end
