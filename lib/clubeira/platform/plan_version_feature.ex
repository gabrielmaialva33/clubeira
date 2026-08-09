defmodule Clubeira.Platform.PlanVersionFeature do
  @moduledoc "Typed feature value frozen into a published plan version."

  use Ecto.Schema

  @primary_key false

  schema "platform_plan_version_features" do
    field :platform_plan_version_id, Ecto.UUID, primary_key: true
    field :platform_feature_id, Ecto.UUID, primary_key: true
    field :value_kind, :string
    field :boolean_value, :boolean
    field :integer_value, :integer
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          platform_plan_version_id: Ecto.UUID.t(),
          platform_feature_id: Ecto.UUID.t(),
          value_kind: String.t(),
          boolean_value: boolean() | nil,
          integer_value: integer() | nil,
          inserted_at: DateTime.t()
        }
end
