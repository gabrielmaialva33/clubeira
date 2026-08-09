defmodule Clubeira.People.UserPersonLink do
  @moduledoc """
  Authorized relationship between a login account and a civil identity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  schema "user_person_links" do
    field :user_id, Ecto.UUID, primary_key: true
    field :person_id, Ecto.UUID, primary_key: true
    field :relationship, :string
    field :status, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t(),
          relationship: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec create_changeset(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(user_id, person_id, %DateTime{} = now) do
    %__MODULE__{}
    |> change(%{
      user_id: user_id,
      person_id: person_id,
      relationship: "self",
      status: "active",
      inserted_at: now,
      updated_at: now
    })
    |> unique_constraint(:user_id, name: :user_person_links_active_self_user_uidx)
  end
end
