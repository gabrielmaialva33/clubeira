defmodule Clubeira.Privacy.RequestSubmission do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :client_request_id, Ecto.UUID
    field :request_type, :string
  end

  @type t :: %__MODULE__{
          client_request_id: Ecto.UUID.t(),
          request_type: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
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
    |> apply_action(:insert)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:insert)
  end
end
