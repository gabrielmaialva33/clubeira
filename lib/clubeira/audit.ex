defmodule Clubeira.Audit do
  @moduledoc """
  Append-only audit writers for tenant-scoped and global operations.
  """

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Tenancy.Scope

  @required_attributes ~w(action resource_type occurred_at)a

  @spec record_tenant!(module(), Scope.t(), map()) :: TenantEvent.t()
  def record_tenant!(repo, %Scope{} = scope, attributes) when is_map(attributes) do
    Enum.each(@required_attributes, &Map.fetch!(attributes, &1))

    %TenantEvent{
      polo_id: scope.polo_id,
      actor_user_id: scope.actor_user_id,
      actor_kind: Map.get(attributes, :actor_kind, actor_kind(scope)),
      action: attributes.action,
      resource_type: attributes.resource_type,
      resource_id: Map.get(attributes, :resource_id),
      request_id: scope.request_id,
      correlation_id: Map.get(attributes, :correlation_id, scope.request_id),
      metadata: Map.get(attributes, :metadata, %{}),
      occurred_at: attributes.occurred_at,
      inserted_at: attributes.occurred_at
    }
    |> repo.insert!()
  end

  @spec record_system!(module(), RequestContext.t(), map()) :: SystemEvent.t()
  def record_system!(repo, %RequestContext{} = context, attributes) when is_map(attributes) do
    Enum.each(@required_attributes, &Map.fetch!(attributes, &1))
    actor_user_id = Map.get(attributes, :actor_user_id)

    %SystemEvent{
      actor_user_id: actor_user_id,
      actor_kind: Map.get(attributes, :actor_kind, system_actor_kind(actor_user_id)),
      action: attributes.action,
      resource_type: attributes.resource_type,
      resource_id: Map.get(attributes, :resource_id),
      request_id: context.request_id,
      correlation_id: Map.get(attributes, :correlation_id, context.request_id),
      metadata: Map.get(attributes, :metadata, %{}),
      occurred_at: attributes.occurred_at,
      inserted_at: attributes.occurred_at
    }
    |> repo.insert!()
  end

  defp actor_kind(%Scope{actor_user_id: nil}), do: "service"
  defp actor_kind(%Scope{}), do: "user"

  defp system_actor_kind(nil), do: "system"
  defp system_actor_kind(_actor_user_id), do: "user"
end
