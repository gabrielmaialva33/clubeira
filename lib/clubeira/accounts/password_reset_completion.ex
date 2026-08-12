defmodule Clubeira.Accounts.PasswordResetCompletion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :token, :string, redact: true
    field :password, :string, redact: true
  end

  @type t :: %__MODULE__{token: String.t(), password: String.t()}

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes |> changeset() |> apply_action(:reset_password)
  end

  def new(_attributes), do: invalid_changeset() |> apply_action(:reset_password)

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:token, :password])
    |> validate_required([:token, :password])
    |> validate_length(:token, min: 43, max: 128)
    |> validate_format(:token, ~r/^[A-Za-z0-9_-]+$/)
    |> validate_length(:password, min: 15, max: 128)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
