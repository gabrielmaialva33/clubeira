defmodule Clubeira.Accounts.EmailVerificationToken do
  @moduledoc """
  Single-use email ownership proof. Only its SHA-256 digest is persisted.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  alias Clubeira.Accounts.User

  schema "user_email_verification_tokens" do
    belongs_to :user, User

    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          user: User.t() | Ecto.Association.NotLoaded.t(),
          token_hash: binary(),
          expires_at: DateTime.t(),
          consumed_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @spec changeset(User.t(), binary(), DateTime.t(), DateTime.t()) :: Ecto.Changeset.t()
  def changeset(%User{} = user, token_hash, expires_at, inserted_at)
      when is_binary(token_hash) and is_struct(expires_at, DateTime) and
             is_struct(inserted_at, DateTime) do
    change(%__MODULE__{},
      user_id: user.id,
      token_hash: token_hash,
      expires_at: expires_at,
      inserted_at: inserted_at
    )
  end
end
