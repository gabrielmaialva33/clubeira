defmodule Clubeira.Accounts.PasswordCredential do
  @moduledoc """
  Optional password credential separated from the global user identity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Accounts.User

  @primary_key false
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "user_password_credentials" do
    belongs_to :user, User, primary_key: true

    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_changed_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          password_hash: String.t(),
          password: String.t() | nil,
          password_changed_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec validate_password(term()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def validate_password(password) do
    changeset =
      %__MODULE__{}
      |> cast(%{password: password}, [:password])
      |> validate_required([:password])
      |> validate_length(:password, min: 15, max: 128)

    if changeset.valid? do
      {:ok, get_change(changeset, :password)}
    else
      {:error, changeset}
    end
  end

  @doc false
  @spec hashed_changeset(User.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def hashed_changeset(%User{} = user, password_hash, %DateTime{} = changed_at)
      when is_binary(password_hash) do
    change(%__MODULE__{},
      user_id: user.id,
      password_hash: password_hash,
      password_changed_at: changed_at
    )
  end

  @doc false
  @spec registration_changeset(User.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def registration_changeset(%User{} = user, password_hash, %DateTime{} = changed_at)
      when is_binary(password_hash) do
    hashed_changeset(user, password_hash, changed_at)
  end
end
