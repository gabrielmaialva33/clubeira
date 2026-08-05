defmodule Clubeira.Redemptions.GrantRequest do
  @moduledoc """
  Validated member request for a short-lived redemption grant.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Devices.InstallationToken

  @primary_key false

  embedded_schema do
    field :entitlement_allocation_id, Ecto.UUID
    field :installation_token, :string, redact: true
  end

  @type t :: %__MODULE__{
          entitlement_allocation_id: Ecto.UUID.t(),
          installation_token: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:entitlement_allocation_id, :installation_token])
    |> validate_required([:entitlement_allocation_id, :installation_token])
    |> validate_length(:installation_token,
      min: InstallationToken.encoded_bytes(),
      max: InstallationToken.encoded_bytes()
    )
    |> validate_change(:installation_token, &validate_token/2)
    |> apply_action(:issue)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:issue)
  end

  @spec token_hash(t()) :: binary()
  def token_hash(%__MODULE__{installation_token: token}) do
    {:ok, token_hash} = InstallationToken.hash(token)
    token_hash
  end

  defp validate_token(field, token) do
    case InstallationToken.hash(token) do
      {:ok, _token_hash} -> []
      :error -> [{field, "must encode exactly 32 random bytes"}]
    end
  end
end
