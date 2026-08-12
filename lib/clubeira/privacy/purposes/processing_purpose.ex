defmodule Clubeira.Privacy.ProcessingPurpose do
  @moduledoc """
  Stable processing purpose and its current legal evidence.
  """

  use Clubeira.Schema

  schema "processing_purposes" do
    field :code, :string
    field :name, :string
    field :legal_basis, :string
    field :legal_document_version_id, Ecto.UUID
    field :status, :string

    timestamps()
  end

  @legal_bases ~w(
    consent
    contract
    legal_obligation
    legitimate_interest
    credit_protection
    fraud_prevention
  )

  @statuses ~w(active retired)
  @put_fields ~w(name legal_basis legal_document_version_id status)a
  @form_fields [:code | @put_fields]

  @doc false
  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attributes, @form_fields)
    |> validate_fields()
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:base, "must be a map")
  end

  @doc false
  def put_changeset(%__MODULE__{} = purpose, attributes, now) do
    purpose
    |> Ecto.Changeset.cast(attributes, @put_fields)
    |> validate_fields()
    |> Ecto.Changeset.unique_constraint(:code,
      name: :processing_purposes_code_index
    )
    |> maybe_touch_updated_at(now)
  end

  defp validate_fields(changeset) do
    changeset
    |> Ecto.Changeset.validate_required([:code, :name, :legal_basis, :status])
    |> Ecto.Changeset.validate_length(:code, min: 2, max: 100)
    |> Ecto.Changeset.validate_format(:code, ~r/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/)
    |> Ecto.Changeset.validate_length(:name, min: 2, max: 160)
    |> Ecto.Changeset.validate_inclusion(:legal_basis, @legal_bases)
    |> Ecto.Changeset.validate_inclusion(:status, @statuses)
    |> validate_consent_document()
  end

  defp validate_consent_document(changeset) do
    case {
      Ecto.Changeset.get_field(changeset, :legal_basis),
      Ecto.Changeset.get_field(changeset, :legal_document_version_id)
    } do
      {"consent", nil} ->
        Ecto.Changeset.add_error(changeset, :legal_document_version_id, "is required")

      _other ->
        changeset
    end
  end

  defp maybe_touch_updated_at(changeset, now) do
    if map_size(changeset.changes) > 0,
      do: Ecto.Changeset.put_change(changeset, :updated_at, now),
      else: changeset
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code: String.t(),
          name: String.t(),
          legal_basis: String.t(),
          legal_document_version_id: Ecto.UUID.t() | nil,
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
