defmodule Clubeira.Reviews.ReviewReportRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @required_fields ~w(place_id review_id reason_code idempotency_key)a
  @optional_fields ~w(details)a
  @reason_codes ~w(spam offensive_content personal_data fraud other)

  embedded_schema do
    field :place_id, Ecto.UUID
    field :review_id, Ecto.UUID
    field :reason_code, :string
    field :details, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          place_id: Ecto.UUID.t(),
          review_id: Ecto.UUID.t(),
          reason_code: String.t(),
          details: String.t() | nil,
          idempotency_key: String.t()
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
    |> apply_action(:report_review)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:report_review)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields ++ @optional_fields)
    |> update_change(:reason_code, &normalize_reason_code/1)
    |> update_change(:details, &normalize_optional_text/1)
    |> validate_required(@required_fields)
    |> validate_inclusion(:reason_code, @reason_codes)
    |> validate_length(:details, max: 1_000)
    |> validate_details_for_other()
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  defp normalize_reason_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_reason_code(value), do: value

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_text(value), do: value

  defp validate_details_for_other(changeset) do
    if get_field(changeset, :reason_code) == "other" and is_nil(get_field(changeset, :details)) do
      add_error(changeset, :details, "is required for other")
    else
      changeset
    end
  end
end
