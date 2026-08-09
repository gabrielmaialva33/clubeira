defmodule Clubeira.Subscriptions.ProductOfferingPublishRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Subscriptions.ProductOfferingBenefitRequest

  @primary_key false
  @fields ~w(
    code name description renewal_policy cycle_policy cycle_interval_unit cycle_interval_count
    effective_from effective_until currency amount idempotency_key
  )a
  @required_fields @fields -- [:effective_until, :renewal_policy]
  @code_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @atom_keys %{
    "allowance_per_cycle" => :allowance_per_cycle,
    "amount" => :amount,
    "benefit_offer_version_id" => :benefit_offer_version_id,
    "benefits" => :benefits,
    "code" => :code,
    "consumption_unit" => :consumption_unit,
    "currency" => :currency,
    "cycle" => :cycle,
    "description" => :description,
    "effective_during" => :effective_during,
    "ends_at" => :ends_at,
    "idempotency_key" => :idempotency_key,
    "interval_count" => :interval_count,
    "interval_unit" => :interval_unit,
    "name" => :name,
    "offering" => :offering,
    "policy" => :policy,
    "price" => :price,
    "renewal_policy" => :renewal_policy,
    "starts_at" => :starts_at
  }

  embedded_schema do
    field :code, :string
    field :name, :string
    field :description, :string
    field :renewal_policy, :string, default: "none"
    field :cycle_policy, :string
    field :cycle_interval_unit, :string
    field :cycle_interval_count, :integer
    field :effective_from, :utc_datetime_usec
    field :effective_until, :utc_datetime_usec
    field :currency, :string
    field :amount, :decimal
    field :idempotency_key, :string

    embeds_many :benefits, ProductOfferingBenefitRequest, on_replace: :delete
  end

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t(),
          description: String.t(),
          renewal_policy: String.t(),
          cycle_policy: String.t(),
          cycle_interval_unit: String.t(),
          cycle_interval_count: pos_integer(),
          effective_from: DateTime.t(),
          effective_until: DateTime.t() | nil,
          currency: String.t(),
          amount: Decimal.t(),
          idempotency_key: String.t(),
          benefits: [ProductOfferingBenefitRequest.t()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    changeset =
      %__MODULE__{}
      |> cast(flatten(attributes), @fields)
      |> cast_embed(:benefits,
        required: true,
        with: &ProductOfferingBenefitRequest.changeset/2
      )
      |> update_change(:code, &String.trim/1)
      |> update_change(:name, &String.trim/1)
      |> update_change(:description, &String.trim/1)
      |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
      |> validate_required(@required_fields)
      |> validate_length(:code, min: 2, max: 80)
      |> validate_format(:code, @code_pattern)
      |> validate_length(:name, min: 2, max: 200)
      |> validate_length(:description, min: 3, max: 5_000)
      |> validate_inclusion(:renewal_policy, ~w(none manual automatic))
      |> validate_inclusion(:cycle_policy, ~w(calendar anniversary))
      |> validate_inclusion(:cycle_interval_unit, ~w(day month year))
      |> validate_number(:cycle_interval_count, greater_than: 0, less_than: 32_768)
      |> validate_length(:currency, is: 3)
      |> validate_format(:currency, ~r/^[A-Z]{3}$/)
      |> validate_number(:amount,
        greater_than: 0,
        less_than: Decimal.new("1000000000000")
      )
      |> validate_decimal_scale(:amount, 2)
      |> validate_length(:idempotency_key, min: 8, max: 128)
      |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
      |> validate_effective_period()
      |> validate_benefits()
      |> normalize_decimal_scale(:amount, 2)

    case apply_action(changeset, :publish_product_offering) do
      {:ok, request} ->
        {:ok,
         %{request | benefits: Enum.sort_by(request.benefits, & &1.benefit_offer_version_id)}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def new(_attributes), do: new(%{})

  defp flatten(attributes) do
    offering = child_map(attributes, "offering")
    cycle = child_map(offering, "cycle")
    effective_during = child_map(offering, "effective_during")
    price = child_map(attributes, "price")

    %{
      code: value(offering, "code"),
      name: value(offering, "name"),
      description: value(offering, "description"),
      renewal_policy: value(offering, "renewal_policy") || "none",
      cycle_policy: value(cycle, "policy"),
      cycle_interval_unit: value(cycle, "interval_unit"),
      cycle_interval_count: value(cycle, "interval_count"),
      effective_from: value(effective_during, "starts_at"),
      effective_until: value(effective_during, "ends_at"),
      currency: value(price, "currency"),
      amount: value(price, "amount"),
      idempotency_key: value(attributes, "idempotency_key"),
      benefits: normalize_benefits(value(attributes, "benefits"))
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

  defp validate_benefits(changeset) do
    benefits = get_field(changeset, :benefits, [])
    ids = Enum.map(benefits, & &1.benefit_offer_version_id)

    cond do
      benefits == [] ->
        add_error(changeset, :benefits, "must not be empty")

      length(benefits) > 100 ->
        add_error(changeset, :benefits, "has too many entries")

      length(ids) != MapSet.size(MapSet.new(ids)) ->
        add_error(changeset, :benefits, "has duplicates")

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

  defp normalize_decimal_scale(changeset, field, scale) do
    update_change(changeset, field, &Decimal.round(&1, scale))
  end

  defp normalize_benefits(benefits) when is_list(benefits) do
    Enum.map(benefits, fn benefit ->
      benefit = if is_map(benefit), do: benefit, else: %{}

      %{
        benefit_offer_version_id: value(benefit, "benefit_offer_version_id"),
        allowance_per_cycle: value(benefit, "allowance_per_cycle"),
        consumption_unit: value(benefit, "consumption_unit")
      }
    end)
  end

  defp normalize_benefits(other), do: other

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
