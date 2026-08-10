defmodule Clubeira.Redemptions.Grant do
  @moduledoc """
  Signed, short-lived authorization binding actor, polo, entitlement, device,
  and replay nonce for one redemption attempt.
  """

  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.Endpoint

  @salt "redemption grant v1"
  @version 1

  @enforce_keys ~w(
    polo_id
    actor_user_id
    entitlement_allocation_id
    device_installation_id
    request_nonce
  )a
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          polo_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t(),
          entitlement_allocation_id: Ecto.UUID.t(),
          device_installation_id: Ecto.UUID.t(),
          request_nonce: String.t()
        }

  @type issued :: %{token: String.t(), expires_at: DateTime.t()}

  @spec issue(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: issued()
  def issue(%Scope{} = scope, allocation_id, device_id, %DateTime{} = now) do
    grant = %__MODULE__{
      polo_id: scope.polo_id,
      actor_user_id: scope.actor_user_id,
      entitlement_allocation_id: allocation_id,
      device_installation_id: device_id,
      request_nonce: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    }

    max_age = max_age_seconds()
    signed_at = DateTime.to_unix(now, :second)

    %{
      token:
        Phoenix.Token.sign(Endpoint, @salt, claims(grant),
          signed_at: signed_at,
          max_age: max_age
        ),
      expires_at: now |> DateTime.truncate(:second) |> DateTime.add(max_age, :second)
    }
  end

  @spec verify(String.t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, :grant_invalid}
  def verify(token, expected_polo_id) when is_binary(token) do
    with {:ok, claims} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: max_age_seconds()),
         {:ok, grant} <- from_claims(claims),
         true <- grant.polo_id == expected_polo_id do
      {:ok, grant}
    else
      _invalid -> {:error, :grant_invalid}
    end
  end

  def verify(_token, _expected_polo_id), do: {:error, :grant_invalid}

  defp claims(grant) do
    %{
      "v" => @version,
      "polo_id" => grant.polo_id,
      "actor_user_id" => grant.actor_user_id,
      "entitlement_allocation_id" => grant.entitlement_allocation_id,
      "device_installation_id" => grant.device_installation_id,
      "request_nonce" => grant.request_nonce
    }
  end

  defp from_claims(%{
         "v" => @version,
         "polo_id" => polo_id,
         "actor_user_id" => actor_user_id,
         "entitlement_allocation_id" => allocation_id,
         "device_installation_id" => device_id,
         "request_nonce" => nonce
       })
       when is_binary(nonce) and byte_size(nonce) in 16..512 do
    with {:ok, polo_id} <- Ecto.UUID.cast(polo_id),
         {:ok, actor_user_id} <- Ecto.UUID.cast(actor_user_id),
         {:ok, allocation_id} <- Ecto.UUID.cast(allocation_id),
         {:ok, device_id} <- Ecto.UUID.cast(device_id) do
      {:ok,
       %__MODULE__{
         polo_id: polo_id,
         actor_user_id: actor_user_id,
         entitlement_allocation_id: allocation_id,
         device_installation_id: device_id,
         request_nonce: nonce
       }}
    else
      :error -> {:error, :grant_invalid}
    end
  end

  defp from_claims(_claims), do: {:error, :grant_invalid}

  defp max_age_seconds do
    :clubeira
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:max_age_seconds)
  end
end
