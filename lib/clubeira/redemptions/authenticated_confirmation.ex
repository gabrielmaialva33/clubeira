defmodule Clubeira.Redemptions.AuthenticatedConfirmation do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Polos
  alias Clubeira.Redemptions
  alias Clubeira.Redemptions.AuthenticatedConfirmationRequest
  alias Clubeira.Redemptions.Grant
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationPoint
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec confirm(String.t(), map(), RequestContext.t()) ::
          {:ok, Clubeira.Redemptions.Redemption.t()} | {:error, term()}
  def confirm(polo_slug, attributes, %RequestContext{} = context) do
    with {:ok, request} <- AuthenticatedConfirmationRequest.new(attributes),
         {:ok, route} <- Polos.resolve_route(polo_slug) do
      service_scope = Scope.new!(route.polo_id, request_id: context.request_id)

      service_scope
      |> confirm_in_scope(request)
      |> unwrap_transaction()
    end
  end

  defp confirm_in_scope(service_scope, request) do
    Repo.transact_in_polo(service_scope, fn repo ->
      with {:ok, grant} <- Grant.verify(request.grant, service_scope.polo_id),
           {:ok, credential} <- authenticate_validation_credential(repo, request) do
        member_scope =
          Scope.new!(service_scope.polo_id,
            actor_user_id: grant.actor_user_id,
            request_id: service_scope.request_id
          )

        result =
          Redemptions.confirm(member_scope, %{
            entitlement_allocation_id: grant.entitlement_allocation_id,
            validation_point_id: credential.validation_point_id,
            device_installation_id: grant.device_installation_id,
            idempotency_key: request.idempotency_key,
            request_nonce: grant.request_nonce,
            request_context: %{
              "channel" => "validation_api",
              "validation_credential_id" => credential.id
            }
          })

        {:ok, result}
      end
    end)
  end

  defp authenticate_validation_credential(repo, request) do
    credential_hash = AuthenticatedConfirmationRequest.credential_hash(request)

    query =
      from credential in ValidationCredential,
        join: point in ValidationPoint,
        on: point.id == credential.validation_point_id and point.polo_id == credential.polo_id,
        where:
          credential.secret_hash == ^credential_hash and
            credential.status == "active" and
            fragment("? @> statement_timestamp()", credential.valid_during) and
            point.status == "active",
        lock: "FOR SHARE",
        select: credential

    case repo.one(query) do
      %ValidationCredential{} = credential -> {:ok, credential}
      nil -> {:error, :validation_credential_invalid}
    end
  end

  defp unwrap_transaction({:ok, {:ok, redemption}}), do: {:ok, redemption}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
