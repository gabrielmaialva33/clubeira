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

  @spec changeset(User.t(), String.t()) :: Ecto.Changeset.t()
  def changeset(%User{} = user, password) do
    now = DateTime.utc_now(:microsecond)

    %__MODULE__{}
    |> change(user_id: user.id, password_changed_at: now)
    |> cast(%{password: password}, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 15, max: 128)
    |> hash_password()
  end

  @doc false
  @spec registration_changeset(User.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def registration_changeset(%User{} = user, password_hash, %DateTime{} = changed_at)
      when is_binary(password_hash) do
    change(%__MODULE__{},
      user_id: user.id,
      password_hash: password_hash,
      password_changed_at: changed_at
    )
  end

  defp hash_password(%Ecto.Changeset{valid?: true} = changeset) do
    password = get_change(changeset, :password)
    put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
  end

  defp hash_password(changeset), do: changeset
end
