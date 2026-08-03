defmodule Clubeira.Tenancy.Scope do
  @moduledoc """
  Carries the authenticated actor and polo boundary through domain operations.

  A scope identifies where an operation is allowed to run. It does not grant
  access by itself; callers must build it only after resolving and authorizing
  the actor for the selected polo.
  """

  @enforce_keys [:polo_id]
  defstruct [:polo_id, :actor_user_id, :request_id, roles: []]

  @type t :: %__MODULE__{
          polo_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          roles: [String.t()]
        }

  @spec new(Ecto.UUID.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(polo_id, options \\ [])

  def new(polo_id, options) when is_list(options) do
    with {:ok, options} <- validate_options(options),
         {:ok, polo_id} <- cast_uuid(polo_id, :invalid_polo_id),
         {:ok, actor_user_id} <-
           cast_optional_uuid(options[:actor_user_id], :invalid_actor_user_id),
         {:ok, request_id} <- cast_optional_uuid(options[:request_id], :invalid_request_id),
         {:ok, roles} <- cast_roles(options[:roles]) do
      {:ok,
       %__MODULE__{
         polo_id: polo_id,
         actor_user_id: actor_user_id,
         request_id: request_id,
         roles: roles
       }}
    end
  end

  def new(_polo_id, _options), do: {:error, :invalid_options}

  @spec new!(Ecto.UUID.t(), keyword()) :: t()
  def new!(polo_id, options \\ []) do
    case new(polo_id, options) do
      {:ok, scope} -> scope
      {:error, reason} -> raise ArgumentError, "invalid tenant scope: #{reason}"
    end
  end

  defp validate_options(options) do
    case Keyword.validate(options, actor_user_id: nil, request_id: nil, roles: []) do
      {:ok, validated} -> {:ok, validated}
      {:error, _unknown_keys} -> {:error, :invalid_options}
    end
  end

  defp cast_optional_uuid(nil, _error), do: {:ok, nil}
  defp cast_optional_uuid(value, error), do: cast_uuid(value, error)

  defp cast_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp cast_roles(roles) when is_list(roles) do
    if Enum.all?(roles, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(roles)}
    else
      {:error, :invalid_roles}
    end
  end

  defp cast_roles(_roles), do: {:error, :invalid_roles}
end
