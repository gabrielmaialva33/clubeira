defmodule Clubeira.Subscriptions.MemberPoloBoundary do
  @moduledoc false

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope, as: TenantScope

  @type route :: %{
          required(:polo_id) => Ecto.UUID.t(),
          required(:slug) => String.t(),
          optional(any()) => any()
        }

  @spec transact(AccountScope.t(), route(), (module(), map() -> term())) :: term()
  def transact(%AccountScope{} = account_scope, route, callback)
      when is_function(callback, 2) do
    scope =
      TenantScope.new!(route.polo_id,
        actor_user_id: account_scope.user.id,
        request_id: account_scope.request_id
      )

    Repo.transact_in_polo(scope, fn repo ->
      case repo.get(Polo, route.polo_id) do
        %Polo{} = polo -> callback.(repo, polo_view(polo, route.slug))
        nil -> {:error, :polo_not_found}
      end
    end)
  end

  defp polo_view(polo, slug) do
    %{
      id: polo.id,
      slug: slug,
      name: polo.name,
      timezone: polo.timezone,
      status: polo.status
    }
  end
end
