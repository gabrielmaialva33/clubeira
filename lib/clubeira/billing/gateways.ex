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
          {:ok, :pending | {:terminal, terminal_payment()} | captured_payment()}
          | {:error, atom()}
  def fetch_payment("mercado_pago", %MerchantAccount{} = account, provider_reference) do
    MercadoPago.fetch_order(account, provider_reference)
  end

  def fetch_payment(_provider, %MerchantAccount{}, _provider_reference) do
    {:error, :payment_gateway_unsupported}
  end
end
