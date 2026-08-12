defmodule Clubeira.People.SelfProfileRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  alias Clubeira.People.Cpf
  alias Clubeira.People.Phone

  @primary_key false

  embedded_schema do
    field :display_name, :string
    field :birth_date, :date
    field :cpf, :string, redact: true
    field :phone, :string, redact: true
    field :cpf_supplied?, :boolean, virtual: true, default: false
    field :phone_supplied?, :boolean, virtual: true, default: false
  end

  @type t :: %__MODULE__{
          display_name: String.t(),
          birth_date: Date.t() | nil,
          cpf: String.t() | nil,
          phone: String.t() | nil,
          cpf_supplied?: boolean(),
          phone_supplied?: boolean()
        }

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> changeset()
    |> apply_action(:update)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:update)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:display_name, :birth_date, :cpf, :phone])
    |> put_change(:cpf_supplied?, supplied?(attributes, :cpf))
    |> put_change(:phone_supplied?, supplied?(attributes, :phone))
    |> update_change(:display_name, &normalize_name/1)
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 2, max: 120)
    |> validate_format(:display_name, ~r/^[^\p{C}]+$/u)
    |> validate_birth_date()
    |> normalize_sensitive(:cpf, &Cpf.cast/1)
    |> normalize_sensitive(:phone, &Phone.cast/1)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  defp supplied?(attributes, key) do
    Map.has_key?(attributes, key) or Map.has_key?(attributes, Atom.to_string(key))
  end

  defp normalize_name(name), do: name |> String.trim() |> String.replace(~r/\s+/u, " ")

  defp validate_birth_date(changeset) do
    validate_change(changeset, :birth_date, fn :birth_date, birth_date ->
      if Date.after?(birth_date, Date.utc_today()),
        do: [birth_date: "must not be in the future"],
        else: []
    end)
  end

  defp normalize_sensitive(changeset, field, caster) do
    case fetch_change(changeset, field) do
      {:ok, nil} ->
        changeset

      {:ok, value} ->
        case caster.(value) do
          {:ok, normalized} -> put_change(changeset, field, normalized)
          :error -> add_error(changeset, field, "is invalid")
        end

      :error ->
        changeset
    end
  end
end
