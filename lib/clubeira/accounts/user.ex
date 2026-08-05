defmodule Clubeira.Accounts.User do
  @moduledoc """
  Global account identity used to authenticate a Clubeira member.

  Sensitive person identifiers remain outside this table. Authentication uses
  the unique email address and an optional credential record.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :status, :string
    field :authenticated_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          email: String.t(),
          status: String.t(),
          authenticated_at: DateTime.t() | nil,
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec registration_changeset(String.t()) :: Ecto.Changeset.t()
  def registration_changeset(email) when is_binary(email) do
    %__MODULE__{}
    |> change(email: email, status: "active")
    |> unique_constraint(:email)
  end
end
