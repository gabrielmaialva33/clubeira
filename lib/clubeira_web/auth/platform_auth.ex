defmodule ClubeiraWeb.PlatformAuth do
  @moduledoc """
  Authorizes browser access to Clubeira's global platform control plane.

  Platform roles are re-read from PostgreSQL and never inferred from polo
  memberships or values stored in the browser session.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  use ClubeiraWeb, :verified_routes
  use Gettext, backend: ClubeiraWeb.Gettext

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.Scope
  alias Clubeira.Polos

  @type access :: %{roles: [String.t()], capabilities: [atom()]}

  @spec authorize(Scope.t()) :: {:ok, access()} | {:error, :forbidden | term()}
  def authorize(%Scope{} = account_scope) do
    case Polos.get_actor_access(account_scope) do
      {:ok, %{platform: %{capabilities: [_capability | _rest]} = access}} -> {:ok, access}
      {:ok, _access} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    locale = Map.get(session, "locale", "pt_BR")
    Gettext.put_locale(ClubeiraWeb.Gettext, locale)

    with token when is_binary(token) <- Map.get(session, "backoffice_session_token"),
         {:ok, account_scope} <-
           Accounts.fetch_scope_by_api_token(token, RequestContext.new!()),
         {:ok, access} <- authorize(account_scope) do
      {:cont,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:platform_access, access)
       |> assign(:locale, locale)}
    else
      _invalid_or_forbidden ->
        {:halt,
         socket
         |> put_flash(
           :error,
           gettext("Your session has expired or does not have platform access.")
         )
         |> redirect(to: ~p"/platform/login")}
    end
  end
end
