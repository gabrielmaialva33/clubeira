defmodule Clubeira.Accounts.Registration do
  @moduledoc """
  Validated credentials for public account registration.

  The password exists only in this short-lived command and is never persisted
  outside its Argon2 digest.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :email, :string
    field :password, :string, redact: true
    field :legal_document_version_ids, {:array, Ecto.UUID}
  end

  @type t :: %__MODULE__{
          email: String.t(),
          password: String.t(),
          legal_document_version_ids: [Ecto.UUID.t()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:email, :password, :legal_document_version_ids])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :password, :legal_document_version_ids])
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:password, min: 15, max: 128)
    |> validate_length(:legal_document_version_ids, min: 1, max: 16)
    |> validate_change(:legal_document_version_ids, &validate_unique_versions/2)
    |> apply_action(:register)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:register)
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp validate_unique_versions(field, version_ids) do
    if length(version_ids) == MapSet.size(MapSet.new(version_ids)) do
      []
    else
      [{field, "must not contain duplicates"}]
    end
  end
end
