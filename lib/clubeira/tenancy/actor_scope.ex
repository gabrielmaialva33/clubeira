defmodule Clubeira.Tenancy.ActorScope do
  @moduledoc """
  Carries an authenticated actor through global, actor-owned lookups.

  This scope deliberately has no polo. It is used only to discover which
  tenant boundaries an authenticated account may enter; tenant data must still
  be read through `Clubeira.Tenancy.Scope`.
  """

  @enforce_keys [:actor_user_id, :request_id]
  defstruct [:actor_user_id, :request_id]

  @type t :: %__MODULE__{
          actor_user_id: Ecto.UUID.t(),
          request_id: Ecto.UUID.t()
        }

  @spec new(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, atom()}
  def new(actor_user_id, request_id) do
    with {:ok, actor_user_id} <- cast_uuid(actor_user_id, :invalid_actor_user_id),
         {:ok, request_id} <- cast_uuid(request_id, :invalid_request_id) do
      {:ok, %__MODULE__{actor_user_id: actor_user_id, request_id: request_id}}
    end
  end

  @spec new!(Ecto.UUID.t(), Ecto.UUID.t()) :: t()
  def new!(actor_user_id, request_id) do
    case new(actor_user_id, request_id) do
      {:ok, scope} -> scope
      {:error, reason} -> raise ArgumentError, "invalid actor scope: #{reason}"
    end
  end

  defp cast_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end
end
