defmodule ClubeiraWeb.PlatformAuthTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Factory
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PlatformAuth

  @password "uma-senha-forte-para-auth-global"

  test "propagates a crossed actor boundary instead of converting it into platform access" do
    operator = Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(operator)
    account_scope = account_scope!(operator)
    other_actor = ActorScope.new!(Factory.insert(:user).id, account_scope.request_id)

    assert {:error, {:tenant_scope_mismatch, :actor_user_id}} =
             Repo.transact_as_actor(other_actor, fn -> PlatformAuth.authorize(account_scope) end)
  end

  defp account_scope!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    account_scope
  end
end
