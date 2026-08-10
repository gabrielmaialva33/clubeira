defmodule Clubeira.Reviews.ReviewMediaRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :storage_key, :string, redact: true
    field :position, :integer
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          storage_key: String.t(),
          position: non_neg_integer(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:storage_key, :position, :idempotency_key])
    |> update_change(:storage_key, &String.trim/1)
    |> validate_required([:storage_key, :position, :idempotency_key])
    |> validate_length(:storage_key, min: 3, max: 512)
    |> validate_format(:storage_key, ~r/^(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9][A-Za-z0-9._\/-]*$/)
    |> validate_number(:position, greater_than_or_equal_to: 0, less_than: 10)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:register_review_media)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:register_review_media)
  end
end
