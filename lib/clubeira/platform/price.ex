defmodule Clubeira.Platform.Price do
  @moduledoc "Time-bounded recurring price of one published platform plan version."

  use Clubeira.Schema

  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Types.TstzRange

  schema "platform_prices" do
    belongs_to :platform_plan_version, PlanVersion

    field :currency, :string
    field :amount, :decimal
    field :billing_interval_unit, :string
    field :billing_interval_count, :integer
    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          platform_plan_version_id: Ecto.UUID.t(),
          currency: String.t(),
          amount: Decimal.t(),
          billing_interval_unit: String.t(),
          billing_interval_count: pos_integer(),
          valid_during: Postgrex.Range.t(),
          inserted_at: DateTime.t()
        }
end
