defmodule Clubeira.Audit do
  @moduledoc """
  Append-only audit writer for tenant-scoped domain operations.
  """

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

  defp actor_kind(%Scope{actor_user_id: nil}), do: "service"
  defp actor_kind(%Scope{}), do: "user"
end
