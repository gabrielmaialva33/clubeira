defmodule Clubeira.Platform.PlanFeatureRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields ~w(key name value_kind boolean_value integer_value)a
  @key_pattern ~r/^[a-z0-9]+(?:_[a-z0-9]+)*$/

  embedded_schema do
    field :key, :string
    field :name, :string
    field :value_kind, :string
    field :boolean_value, :boolean
    field :integer_value, :integer
  end

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          value_kind: String.t(),
          boolean_value: boolean() | nil,
          integer_value: integer() | nil
        }

  def changeset(feature, attributes) do
    feature
    |> cast(attributes, @fields)
    |> update_change(:key, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required(~w(key name value_kind)a)
    |> validate_length(:key, min: 2, max: 80)
    |> validate_format(:key, @key_pattern)
    |> validate_length(:name, min: 2, max: 160)
    |> validate_inclusion(:value_kind, ~w(boolean integer))
    |> validate_number(:integer_value, greater_than_or_equal_to: 0)
    |> validate_typed_value()
  end

  defp validate_typed_value(changeset) do
    case {
      get_field(changeset, :value_kind),
      get_field(changeset, :boolean_value),
      get_field(changeset, :integer_value)
    } do
      {"boolean", value, nil} when is_boolean(value) -> changeset
      {"integer", nil, value} when is_integer(value) -> changeset
      {nil, _, _} -> changeset
      _invalid -> add_error(changeset, :value_kind, "does not match its value")
    end
  end
end
