defmodule Clubeira.Directory.PartnerOnboardingRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  alias Clubeira.Directory.Cnpj

  @primary_key false
  @fields ~w(
    legal_name
    trade_name
    cnpj
    place_name
    place_slug
    postal_code
    street
    number
    complement
    district
    idempotency_key
  )a
  @required_fields @fields -- [:complement]
  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @atom_keys %{
    "address" => :address,
    "cnpj" => :cnpj,
    "complement" => :complement,
    "district" => :district,
    "idempotency_key" => :idempotency_key,
    "legal_name" => :legal_name,
    "name" => :name,
    "number" => :number,
    "organization" => :organization,
    "place" => :place,
    "postal_code" => :postal_code,
    "slug" => :slug,
    "street" => :street,
    "trade_name" => :trade_name
  }

  embedded_schema do
    field :legal_name, :string
    field :trade_name, :string
    field :cnpj, :string
    field :place_name, :string
    field :place_slug, :string
    field :postal_code, :string
    field :street, :string
    field :number, :string
    field :complement, :string
    field :district, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          legal_name: String.t(),
          trade_name: String.t(),
          cnpj: String.t(),
          place_name: String.t(),
          place_slug: String.t(),
          postal_code: String.t(),
          street: String.t(),
          number: String.t(),
          complement: String.t() | nil,
          district: String.t(),
          idempotency_key: String.t()
        }

  @doc """
  Builds a presentation changeset from the flat partner onboarding form.

  The command constructor in `new/1` intentionally keeps accepting the nested
  public API payload and normalizes it before applying domain validations.
  """
  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    cast(%__MODULE__{}, attributes, @fields)
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    changeset =
      %__MODULE__{}
      |> cast(flatten(attributes), @fields)
      |> update_change(:legal_name, &String.trim/1)
      |> update_change(:trade_name, &String.trim/1)
      |> update_change(:place_name, &String.trim/1)
      |> update_change(:place_slug, &String.trim/1)
      |> update_change(:street, &String.trim/1)
      |> update_change(:number, &String.trim/1)
      |> update_change(:complement, &normalize_optional_text/1)
      |> update_change(:district, &String.trim/1)
      |> normalize_postal_code()
      |> normalize_cnpj()
      |> validate_required(@required_fields)
      |> validate_length(:legal_name, min: 3, max: 200)
      |> validate_length(:trade_name, min: 2, max: 160)
      |> validate_length(:place_name, min: 2, max: 160)
      |> validate_length(:place_slug, min: 2, max: 120)
      |> validate_format(:place_slug, @slug_pattern)
      |> validate_length(:street, min: 2, max: 200)
      |> validate_length(:number, min: 1, max: 40)
      |> validate_length(:complement, max: 120)
      |> validate_length(:district, min: 2, max: 120)
      |> validate_length(:idempotency_key, min: 8, max: 128)
      |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)

    apply_action(changeset, :insert)
  end

  def new(_attributes), do: new(%{})

  defp flatten(attributes) do
    organization = child_map(attributes, "organization")
    place = child_map(attributes, "place")
    address = child_map(place, "address")

    %{
      legal_name: value(organization, "legal_name"),
      trade_name: value(organization, "trade_name"),
      cnpj: value(organization, "cnpj"),
      place_name: value(place, "name"),
      place_slug: value(place, "slug"),
      postal_code: value(address, "postal_code"),
      street: value(address, "street"),
      number: value(address, "number"),
      complement: value(address, "complement"),
      district: value(address, "district"),
      idempotency_key: value(attributes, "idempotency_key")
    }
  end

  defp normalize_cnpj(changeset) do
    case fetch_change(changeset, :cnpj) do
      {:ok, value} ->
        case Cnpj.normalize(value) do
          {:ok, normalized} -> put_change(changeset, :cnpj, normalized)
          {:error, :invalid_cnpj} -> add_error(changeset, :cnpj, "is invalid")
        end

      :error ->
        changeset
    end
  end

  defp normalize_postal_code(changeset) do
    changeset
    |> update_change(:postal_code, &String.replace(&1, ~r/[.\-\s]/u, ""))
    |> validate_format(:postal_code, ~r/^\d{8}$/)
  end

  defp normalize_optional_text(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
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
