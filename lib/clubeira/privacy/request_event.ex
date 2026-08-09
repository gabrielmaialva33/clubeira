defmodule Clubeira.Privacy.RequestEvent do
  @moduledoc """
  Append-only lifecycle evidence for a data-subject request.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "privacy_request_events" do
    field :privacy_request_id, Ecto.UUID
    field :actor_user_id, Ecto.UUID
    field :event_type, :string
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          privacy_request_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          event_type: String.t(),
          payload: map(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  @doc false
  @spec create_changeset(map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(attributes, %DateTime{} = now) when is_map(attributes) do
    %__MODULE__{}
    |> change(Map.merge(attributes, %{occurred_at: now, inserted_at: now}))
    |> foreign_key_constraint(:privacy_request_id)
    |> foreign_key_constraint(:actor_user_id)
  end
end
