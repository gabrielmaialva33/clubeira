defmodule ClubeiraWeb.BackofficeAuth do
  @moduledoc """
  Authenticates browser sessions and derives the current backoffice access map.

  The browser cookie contains an encrypted opaque API token. Authorization is
  still re-read from PostgreSQL every time a LiveView mounts; the cookie never
  carries roles, capabilities or a trusted tenant identifier.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  use ClubeiraWeb, :verified_routes
  use Gettext, backend: ClubeiraWeb.Gettext

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.Scope
  alias Clubeira.Polos

  @backoffice_capabilities [
    :manage_billing,
    :manage_operations,
    :manage_partners,
    :moderate_reviews
  ]

  @type access :: %{platform: map(), polos: [map()]}

  @spec authorize(Scope.t()) :: {:ok, access()} | {:error, :forbidden | term()}
  def authorize(%Scope{} = account_scope) do
    case Polos.get_actor_access(account_scope) do
      {:ok, access} -> retain_backoffice_polos(access)
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
       |> assign(:backoffice_access, access)
       |> assign(:locale, locale)}
    else
      _invalid_or_forbidden ->
        {:halt,
         socket
         |> put_flash(
           :error,
           gettext("Your session has expired or does not have backoffice access.")
         )
         |> redirect(to: ~p"/admin/login")}
    end
  end

  defp retain_backoffice_polos(access) do
    polos = Enum.filter(access.polos, &backoffice_polo?/1)

    if polos == [] do
      {:error, :forbidden}
    else
      {:ok, %{access | polos: polos}}
    end
  end

  defp backoffice_polo?(polo) do
    Enum.any?(polo.capabilities, &(&1 in @backoffice_capabilities))
  end
end
