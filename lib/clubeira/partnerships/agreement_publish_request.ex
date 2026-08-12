defmodule Clubeira.Partnerships.AgreementPublishRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :agreement_number, :string
    field :name, :string
    field :valid_from, :utc_datetime_usec
    field :valid_until, :utc_datetime_usec
    field :signed_at, :utc_datetime_usec
    field :settlement_model, :string
    field :redemption_sla_seconds, :integer
    field :organization_ids, {:array, Ecto.UUID}, default: []
    field :brand_ids, {:array, Ecto.UUID}, default: []
    field :polo_place_ids, {:array, Ecto.UUID}, default: []
    field :edition_ids, {:array, Ecto.UUID}, default: []
    field :benefit_offer_version_ids, {:array, Ecto.UUID}, default: []
    field :idempotency_key, :string
  end

  @fields ~w(
    agreement_number
    name
    valid_from
    valid_until
    signed_at
    settlement_model
    redemption_sla_seconds
    organization_ids
    brand_ids
    polo_place_ids
    edition_ids
    benefit_offer_version_ids
    idempotency_key
  )a

  @required ~w(
    agreement_number
    name
    valid_from
    valid_until
    signed_at
    settlement_model
    redemption_sla_seconds
    organization_ids
    polo_place_ids
    benefit_offer_version_ids
    idempotency_key
  )a

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    cast(%__MODULE__{}, attributes, @fields)
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec new(term()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> change()
    |> update_change(:agreement_number, &normalize_number/1)
    |> update_change(:name, &String.trim/1)
    |> normalize_ids()
    |> validate_required(@required)
    |> validate_length(:agreement_number, min: 3, max: 80)
    |> validate_format(:agreement_number, ~r/^[A-Z0-9][A-Z0-9._\/-]*$/)
    |> validate_length(:name, min: 3, max: 200)
    |> validate_inclusion(:settlement_model, ~w(none fixed revenue_share))
    |> validate_number(:redemption_sla_seconds,
      greater_than: 0,
      less_than_or_equal_to: 86_400
    )
    |> validate_length(:organization_ids, min: 1, max: 50)
    |> validate_length(:brand_ids, max: 100)
    |> validate_length(:polo_place_ids, min: 1, max: 500)
    |> validate_length(:edition_ids, max: 100)
    |> validate_length(:benefit_offer_version_ids, min: 1, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> validate_range()
    |> apply_action(:publish_partner_agreement)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:publish_partner_agreement)
  end

  defp normalize_number(value), do: value |> String.trim() |> String.upcase()

  defp normalize_ids(changeset) do
    Enum.reduce(
      ~w(organization_ids brand_ids polo_place_ids edition_ids benefit_offer_version_ids)a,
      changeset,
      fn field, current -> update_change(current, field, &Enum.uniq/1) end
    )
  end

  defp validate_range(changeset) do
    case {get_field(changeset, :valid_from), get_field(changeset, :valid_until)} do
      {%DateTime{} = from, %DateTime{} = until} ->
        if DateTime.before?(from, until),
          do: changeset,
          else: add_error(changeset, :valid_until, "must be after valid_from")

      _missing ->
        changeset
    end
  end
end
