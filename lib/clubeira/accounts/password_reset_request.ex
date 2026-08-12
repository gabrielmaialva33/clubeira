defmodule Clubeira.Accounts.PasswordResetRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :email, :string
  end

  @type t :: %__MODULE__{email: String.t()}

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes |> changeset() |> apply_action(:request_password_reset)
  end

  def new(_attributes), do: invalid_changeset() |> apply_action(:request_password_reset)

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email])
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
