defmodule Clubeira.Platform.PlanPublishRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Platform.PlanFeatureRequest

  @primary_key false
  @fields ~w(
    name version_name description currency amount billing_interval_unit
    billing_interval_count valid_from valid_until
  )a

  embedded_schema do
    field :name, :string
    field :version_name, :string
    field :description, :string
    field :currency, :string
    field :amount, :decimal
    field :billing_interval_unit, :string
    field :billing_interval_count, :integer
    field :valid_from, :utc_datetime_usec
    field :valid_until, :utc_datetime_usec

    embeds_many :features, PlanFeatureRequest, on_replace: :delete
  end

  @type t :: %__MODULE__{
          name: String.t(),
          version_name: String.t(),
          description: String.t(),
          currency: String.t(),
          amount: Decimal.t(),
          billing_interval_unit: String.t(),
          billing_interval_count: pos_integer(),
          valid_from: DateTime.t(),
          valid_until: DateTime.t(),
          features: [PlanFeatureRequest.t()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    changeset =
      %__MODULE__{}
      |> cast(flatten(attributes), @fields)
      |> cast_embed(:features, required: true, with: &PlanFeatureRequest.changeset/2)
      |> update_change(:name, &String.trim/1)
      |> update_change(:version_name, &String.trim/1)
      |> update_change(:description, &String.trim/1)
      |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
      |> validate_required(@fields)
      |> validate_length(:name, min: 2, max: 160)
      |> validate_length(:version_name, min: 2, max: 160)
      |> validate_length(:description, min: 3, max: 5_000)
      |> validate_length(:currency, is: 3)
      |> validate_format(:currency, ~r/^[A-Z]{3}$/)
      |> validate_number(:amount,
        greater_than_or_equal_to: 0,
        less_than: Decimal.new("1000000000000")
      )
      |> validate_number(:billing_interval_count, greater_than: 0, less_than: 32_768)
      |> validate_inclusion(:billing_interval_unit, ~w(month year))
      |> validate_decimal_scale(:amount, 2)
      |> validate_period()
      |> validate_feature_set()
      |> update_change(:amount, &Decimal.round(&1, 2))

    case apply_action(changeset, :publish_platform_plan) do
      {:ok, request} ->
        {:ok, %{request | features: Enum.sort_by(request.features, & &1.key)}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def new(_attributes), do: new(%{})

  defp flatten(attributes) do
    price = child_map(attributes, "price")

    %{
      name: value(attributes, "name"),
      version_name: value(attributes, "version_name"),
      description: value(attributes, "description"),
      features: value(attributes, "features"),
      currency: value(price, "currency"),
      amount: value(price, "amount"),
      billing_interval_unit: value(price, "billing_interval_unit"),
      billing_interval_count: value(price, "billing_interval_count"),
      valid_from: value(price, "valid_from"),
      valid_until: value(price, "valid_until")
    }
  end

  defp validate_period(changeset) do
    from = get_field(changeset, :valid_from)
    until = get_field(changeset, :valid_until)

    if from && until && DateTime.compare(until, from) != :gt,
      do: add_error(changeset, :valid_until, "must be after valid_from"),
      else: changeset
  end

  defp validate_feature_set(changeset) do
    features = get_field(changeset, :features, [])
    keys = Enum.map(features, & &1.key)

    cond do
      features == [] ->
        add_error(changeset, :features, "must not be empty")

      length(features) > 100 ->
        add_error(changeset, :features, "has too many entries")

      length(keys) != MapSet.size(MapSet.new(keys)) ->
        add_error(changeset, :features, "has duplicate keys")

      true ->
        changeset
    end
  end

  defp validate_decimal_scale(changeset, field, maximum_scale) do
    validate_change(changeset, field, fn ^field, value ->
      if value |> Decimal.normalize() |> Decimal.scale() <= maximum_scale,
        do: [],
        else: [{field, "has too many decimal places"}]
    end)
  end

  defp child_map(map, key) do
    case value(map, key) do
      child when is_map(child) -> child
      _other -> %{}
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  end
end
