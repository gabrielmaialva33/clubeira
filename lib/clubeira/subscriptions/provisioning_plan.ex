defmodule Clubeira.Subscriptions.ProvisioningPlan do
  @moduledoc false

  @enforce_keys [:configuration, :benefits_during, :allocation_specs]
  defstruct [:configuration, :benefits_during, :allocation_specs]

  @type allocation_spec :: %{
          item: Clubeira.Subscriptions.BenefitPackageItem.t(),
          polo_place_id: Ecto.UUID.t() | nil,
          issued_units: pos_integer()
        }

  @type t :: %__MODULE__{
          configuration: map(),
          benefits_during: Postgrex.Range.t(),
          allocation_specs: [allocation_spec()]
        }
end
