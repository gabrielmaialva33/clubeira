defmodule Clubeira.Platform.PoloSubscription do
  @moduledoc "Recurring SaaS agreement between one polo and Clubeira."

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.Price
  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "polo_platform_subscriptions" do
    belongs_to :polo, Polo
    belongs_to :platform_plan_version, PlanVersion
    belongs_to :platform_price, Price
    belongs_to :merchant_account, MerchantAccount
    belongs_to :requested_by_user, User

    field :provider_reference, :string
    field :idempotency_key, :string
    field :request_sha256, :binary
    field :status, :string
    field :current_period, TstzRange
    field :next_action, :map
    field :next_charge_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          platform_plan_version_id: Ecto.UUID.t(),
          platform_price_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          requested_by_user_id: Ecto.UUID.t() | nil,
          provider_reference: String.t() | nil,
          idempotency_key: String.t() | nil,
          request_sha256: binary() | nil,
          status: String.t(),
          current_period: Postgrex.Range.t() | nil,
          next_action: map(),
          next_charge_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
