defmodule Clubeira.Devices.RedemptionEnrollmentRequest do
  @moduledoc """
  Validated public command for enrolling an installation in a contract.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Devices.InstallationToken

  @primary_key false
  @platforms ~w(android ios web)

  embedded_schema do
    field :access_contract_id, Ecto.UUID
    field :installation_token, :string, redact: true
    field :platform, :string
  end

  @type t :: %__MODULE__{
          access_contract_id: Ecto.UUID.t(),
          installation_token: String.t(),
          platform: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:access_contract_id, :installation_token, :platform])
    |> validate_required([:access_contract_id, :installation_token, :platform])
    |> validate_inclusion(:platform, @platforms)
    |> validate_length(:installation_token,
      min: InstallationToken.encoded_bytes(),
      max: InstallationToken.encoded_bytes()
    )
    |> validate_change(:installation_token, &validate_token/2)
    |> apply_action(:enroll)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:enroll)
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
