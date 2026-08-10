defmodule Clubeira.Billing.Gateways do
  @moduledoc false

  alias Clubeira.Billing.Gateways.Adapter
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

  @type webhook_envelope :: %{
          required(:body_params) => map(),
          required(:headers) => %{optional(String.t()) => [String.t()]},
          required(:query_params) => map(),
          required(:raw_body) => binary()
        }

  @type webhook_event :: %{
          required(:external_event_id) => String.t(),
          required(:kind) => :chargeback | :payment | :recurring_invoice,
          required(:provider_reference) => String.t(),
          optional(:provider_payment_reference) => String.t()
        }

  @spec adapter_for(String.t()) :: {:ok, module()} | {:error, :payment_gateway_unsupported}
  def adapter_for(provider_code) when is_binary(provider_code) do
    case gateway_configuration() |> Keyword.get(:adapters, %{}) |> Map.fetch(provider_code) do
      {:ok, adapter} when is_atom(adapter) ->
        if valid_adapter?(adapter),
          do: {:ok, adapter},
          else: {:error, :payment_gateway_unsupported}

      _missing_or_invalid ->
        {:error, :payment_gateway_unsupported}
    end
  end

  def adapter_for(_provider_code), do: {:error, :payment_gateway_unsupported}

  @spec provider_for_payment(String.t()) ::
          {:ok, String.t()} | {:error, :payment_gateway_unsupported}
  def provider_for_payment(payment_method) when is_binary(payment_method) do
    with {:ok, provider_code} <-
           gateway_configuration()
           |> Keyword.get(:payment_providers, %{})
           |> Map.fetch(payment_method),
         true <- is_binary(provider_code),
         {:ok, _adapter} <- adapter_for(provider_code) do
      {:ok, provider_code}
    else
      _missing_or_invalid -> {:error, :payment_gateway_unsupported}
    end
  end

  def provider_for_payment(_payment_method), do: {:error, :payment_gateway_unsupported}

  @spec provider_for_subscription() ::
          {:ok, String.t()} | {:error, :payment_gateway_unsupported}
  def provider_for_subscription do
    case Keyword.get(gateway_configuration(), :subscription_provider) do
      provider_code when is_binary(provider_code) ->
        case adapter_for(provider_code) do
          {:ok, _adapter} -> {:ok, provider_code}
          {:error, _reason} = error -> error
        end

      _missing_or_invalid ->
        {:error, :payment_gateway_unsupported}
    end
  end

  @spec create_payment(String.t(), MerchantAccount.t(), String.t(), payment_request()) ::
          {:ok, created_payment()} | {:error, atom()}
  def create_payment(provider, %MerchantAccount{} = account, payment_method, request) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.create_payment(account, payment_method, request)
    end
  end

  @spec create_subscription(String.t(), MerchantAccount.t(), subscription_request()) ::
          {:ok, created_subscription()} | {:error, atom()}
  def create_subscription(provider, %MerchantAccount{} = account, request) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.create_subscription(account, request)
    end
  end

  @spec refund_payment(String.t(), MerchantAccount.t(), String.t(), refund_request()) ::
          {:ok, refunded_payment()} | {:error, atom()}
  def refund_payment(provider, %MerchantAccount{} = account, provider_reference, request) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.refund_payment(account, provider_reference, request)
    end
  end

  @spec verify_webhook(String.t(), MerchantAccount.t(), webhook_envelope()) ::
          {:ok, webhook_event()} | {:error, atom()}
  def verify_webhook(provider, %MerchantAccount{} = account, envelope) when is_map(envelope) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.verify_webhook(account, envelope)
    end
  end

  @spec fetch_payment(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok,
           :pending
           | {:terminal, terminal_payment()}
           | {:refunded, refunded_payment()}
           | captured_payment()}
          | {:error, atom()}
  def fetch_payment(provider, %MerchantAccount{} = account, provider_reference) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.fetch_payment(account, provider_reference)
    end
  end

  @spec fetch_recurring_invoice(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok, recurring_invoice() | platform_invoice()} | {:error, atom()}
  def fetch_recurring_invoice(provider, %MerchantAccount{} = account, reference) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.fetch_recurring_invoice(account, reference)
    end
  end

  @spec fetch_chargeback(String.t(), MerchantAccount.t(), String.t()) ::
          {:ok, chargeback()} | {:error, atom()}
  def fetch_chargeback(provider, %MerchantAccount{} = account, reference) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter.fetch_chargeback(account, reference)
    end
  end

  defp gateway_configuration do
    Application.get_env(:clubeira, __MODULE__, [])
  end

  defp valid_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?(Adapter.behaviour_info(:callbacks), fn {function, arity} ->
        function_exported?(adapter, function, arity)
      end)
  end
end
