defmodule Clubeira.Privacy.Request do
  @moduledoc """
  Data-subject request with an idempotent client identity and lifecycle state.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "privacy_requests" do
    field :requester_user_id, Ecto.UUID
    field :person_id, Ecto.UUID
    field :client_request_id, Ecto.UUID
    field :request_sha256, :binary, redact: true
    field :request_type, :string
    field :status, :string
    field :due_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :rejection_reason, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          requester_user_id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t(),
          client_request_id: Ecto.UUID.t(),
          request_sha256: binary(),
          request_type: String.t(),
          status: String.t(),
          due_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          rejection_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> change(attributes)
    |> unique_constraint(:client_request_id,
      name: :privacy_requests_actor_client_request_uidx
    )
    |> foreign_key_constraint(:requester_user_id)
    |> foreign_key_constraint(:person_id)
  end
end
