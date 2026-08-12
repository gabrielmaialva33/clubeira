defmodule Clubeira.Privacy.RequestSubmission do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :client_request_id, Ecto.UUID
    field :request_type, :string
  end

  @type t :: %__MODULE__{
          client_request_id: Ecto.UUID.t(),
          request_type: String.t()
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
    |> apply_action(:insert)
  end

  def new(_attributes) do
    invalid_changeset()
    |> apply_action(:insert)
  end

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:client_request_id, :request_type])
    |> validate_required([:client_request_id, :request_type])
    |> validate_inclusion(:request_type, ~w(
      access
      confirmation
      correction
      portability
      deletion
      anonymization
      consent_withdrawal
      information
    ))
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
