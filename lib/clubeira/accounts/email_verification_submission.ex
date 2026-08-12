defmodule Clubeira.Accounts.EmailVerificationSubmission do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :token, :string, redact: true
  end

  @type t :: %__MODULE__{token: String.t()}

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes),
    do: changeset(attributes)

  def change(_attributes), do: invalid_changeset()

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes |> changeset() |> apply_action(:verify_email)
  end

  def new(_attributes), do: invalid_changeset() |> apply_action(:verify_email)

  defp changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:token])
    |> validate_required([:token])
    |> validate_length(:token, min: 43, max: 128)
    |> validate_format(:token, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp invalid_changeset do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end
end
