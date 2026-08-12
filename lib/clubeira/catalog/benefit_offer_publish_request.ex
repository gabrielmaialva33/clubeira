defmodule Clubeira.Catalog.BenefitOfferPublishRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @fields ~w(
    code
    name
    benefit_kind
    title
    description
    terms
    redemption_instructions
    percentage_value
    amount_value
    currency
    effective_from
    effective_until
    idempotency_key
  )a
  @required_fields @fields -- [:percentage_value, :amount_value, :currency, :effective_until]
  @benefit_kinds ~w(discount_percentage discount_amount complimentary_item bundle custom)
  @code_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @atom_keys %{
    "amount_value" => :amount_value,
    "benefit_kind" => :benefit_kind,
    "code" => :code,
    "currency" => :currency,
    "description" => :description,
    "effective_during" => :effective_during,
    "ends_at" => :ends_at,
    "idempotency_key" => :idempotency_key,
    "name" => :name,
    "offer" => :offer,
    "percentage_value" => :percentage_value,
    "redemption_instructions" => :redemption_instructions,
    "starts_at" => :starts_at,
    "terms" => :terms,
    "title" => :title,
    "version" => :version
  }

  embedded_schema do
    field :code, :string
    field :name, :string
    field :benefit_kind, :string
    field :title, :string
    field :description, :string
    field :terms, :string
    field :redemption_instructions, :string
    field :percentage_value, :decimal
    field :amount_value, :decimal
    field :currency, :string
    field :effective_from, :utc_datetime_usec
    field :effective_until, :utc_datetime_usec
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t(),
          benefit_kind: String.t(),
          title: String.t(),
          description: String.t(),
          terms: String.t(),
          redemption_instructions: String.t(),
          percentage_value: Decimal.t() | nil,
          amount_value: Decimal.t() | nil,
          currency: String.t() | nil,
          effective_from: DateTime.t(),
          effective_until: DateTime.t() | nil,
          idempotency_key: String.t()
        }

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    changeset(attributes)
  end

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> flatten()
    |> changeset()
    |> apply_action(:publish_benefit_offer)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:publish_benefit_offer)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:title, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> update_change(:terms, &String.trim/1)
    |> update_change(:redemption_instructions, &String.trim/1)
    |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required(@required_fields)
    |> validate_length(:code, min: 2, max: 80)
    |> validate_format(:code, @code_pattern)
    |> validate_length(:name, min: 2, max: 160)
    |> validate_length(:title, min: 2, max: 200)
    |> validate_length(:description, min: 3, max: 5_000)
    |> validate_length(:terms, min: 2, max: 5_000)
    |> validate_length(:redemption_instructions, min: 2, max: 2_000)
    |> validate_inclusion(:benefit_kind, @benefit_kinds)
    |> validate_number(:percentage_value, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_decimal_scale(:percentage_value, 4)
    |> validate_number(:amount_value,
      greater_than: 0,
      less_than: Decimal.new("1000000000000")
    )
    |> validate_decimal_scale(:amount_value, 2)
    |> validate_length(:currency, is: 3)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> validate_effective_period()
    |> validate_benefit_value()
    |> normalize_decimal_scale(:percentage_value, 4)
    |> normalize_decimal_scale(:amount_value, 2)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  defp flatten(attributes) do
    offer = child_map(attributes, "offer")
    version = child_map(attributes, "version")
    effective_during = child_map(version, "effective_during")

    %{
      code: value(offer, "code"),
      name: value(offer, "name"),
      benefit_kind: value(offer, "benefit_kind"),
      title: value(version, "title"),
      description: value(version, "description"),
      terms: value(version, "terms"),
      redemption_instructions: value(version, "redemption_instructions"),
      percentage_value: value(version, "percentage_value"),
      amount_value: value(version, "amount_value"),
      currency: value(version, "currency"),
      effective_from: value(effective_during, "starts_at"),
      effective_until: value(effective_during, "ends_at"),
      idempotency_key: value(attributes, "idempotency_key")
    }
  end

  defp validate_effective_period(changeset) do
    starts_at = get_field(changeset, :effective_from)
    ends_at = get_field(changeset, :effective_until)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      add_error(changeset, :effective_until, "must be after starts_at")
    else
      changeset
    end
  end

  defp validate_benefit_value(changeset) do
    kind = get_field(changeset, :benefit_kind)
    percentage = get_field(changeset, :percentage_value)
    amount = get_field(changeset, :amount_value)
    currency = get_field(changeset, :currency)

    if benefit_value_valid?(kind, percentage, amount, currency),
      do: changeset,
      else: add_error(changeset, :benefit_kind, "has invalid values")
  end

  defp benefit_value_valid?("discount_percentage", percentage, nil, nil)
       when not is_nil(percentage),
       do: true

  defp benefit_value_valid?("discount_percentage", _percentage, _amount, _currency), do: false

  defp benefit_value_valid?("discount_amount", nil, amount, currency)
       when not is_nil(amount) and not is_nil(currency),
       do: true

  defp benefit_value_valid?("discount_amount", _percentage, _amount, _currency), do: false

  defp benefit_value_valid?(kind, nil, nil, nil)
       when kind in ~w(complimentary_item bundle custom),
       do: true

  defp benefit_value_valid?(kind, _percentage, _amount, _currency)
       when kind in ~w(complimentary_item bundle custom),
       do: false

  defp benefit_value_valid?(_kind, _percentage, _amount, _currency), do: true

  defp validate_decimal_scale(changeset, field, maximum_scale) do
    validate_change(changeset, field, fn ^field, value ->
      if value |> Decimal.normalize() |> Decimal.scale() <= maximum_scale,
        do: [],
        else: [{field, "has too many decimal places"}]
    end)
  end

  defp normalize_decimal_scale(changeset, field, scale) do
    update_change(changeset, field, &Decimal.round(&1, scale))
  end

  defp child_map(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@atom_keys, key))
    end
  end
end
