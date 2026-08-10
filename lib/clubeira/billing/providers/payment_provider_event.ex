defmodule Clubeira.Billing.PaymentProviderEvent do
  @moduledoc """
  Deduplicated, tenant-routed payment provider event with a sanitized payload.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Polos.Polo

  schema "payment_provider_events" do
    belongs_to :payment_provider, PaymentProvider
    belongs_to :merchant_account, MerchantAccount
    belongs_to :polo, Polo

    field :external_event_id, :string
    field :event_type, :string
    field :payload, :map
    field :payload_sha256, :binary
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :processing_error, :string
  end
end
