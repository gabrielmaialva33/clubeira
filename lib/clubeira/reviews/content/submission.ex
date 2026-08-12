defmodule Clubeira.Reviews.Submission do
  @moduledoc """
  Validated member-authored content and redemption proof for a new review.
  """

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @required_fields ~w(place_id source_redemption_id rating body idempotency_key)a
  @optional_fields ~w(title)a

  embedded_schema do
    field :place_id, Ecto.UUID
    field :source_redemption_id, Ecto.UUID
    field :rating, :integer
    field :title, :string
    field :body, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          place_id: Ecto.UUID.t(),
          source_redemption_id: Ecto.UUID.t(),
          rating: 1..5,
          title: String.t() | nil,
          body: String.t(),
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
    |> apply_action(:submit_review)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:submit_review)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @required_fields ++ @optional_fields)
    |> update_change(:title, &normalize_optional_text/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required(@required_fields)
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_length(:title, max: 120)
    |> validate_length(:body, max: 5_000)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  defp normalize_optional_text(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end
end
