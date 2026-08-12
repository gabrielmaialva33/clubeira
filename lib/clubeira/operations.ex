defmodule Clubeira.Operations do
  @moduledoc """
  Tenant-scoped operational read models and recovery commands.
  """

  alias Clubeira.Operations.BackofficeAuditReader
  alias Clubeira.Operations.BackofficeOutboxReader
  alias Clubeira.Operations.OutboxRetry
  alias Clubeira.Operations.OutboxRetryRequest
  alias Clubeira.Tenancy.Scope

  @spec list_backoffice_outbox_messages(Scope.t(), map()) ::
          {:ok, %{messages: [map()], page: map()}} | {:error, term()}
  defdelegate list_backoffice_outbox_messages(scope, params),
    to: BackofficeOutboxReader,
    as: :list

  @spec list_backoffice_audit_events(Scope.t(), map()) ::
          {:ok, %{events: [map()], page: map()}} | {:error, term()}
  defdelegate list_backoffice_audit_events(scope, params),
    to: BackofficeAuditReader,
    as: :list

  @spec retry_outbox_message(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate retry_outbox_message(scope, message_id, attributes),
    to: OutboxRetry,
    as: :retry

  @doc false
  @spec change_outbox_retry_request(term()) :: Ecto.Changeset.t()
  def change_outbox_retry_request(attributes \\ %{}) do
    OutboxRetryRequest.change(attributes)
  end
end
