defmodule Clubeira.People.Person do
  @moduledoc """
  Civil identity kept separate from the authentication account.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "persons" do
    field :display_name, :string
    field :birth_date, :date
    field :status, :string
    field :anonymized_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          display_name: String.t(),
          birth_date: Date.t() | nil,
          status: String.t(),
          anonymized_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(%__MODULE__{} = person, attributes) when is_map(attributes) do
    person
    |> cast(attributes, [:display_name, :birth_date])
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 2, max: 120)
  end
end
