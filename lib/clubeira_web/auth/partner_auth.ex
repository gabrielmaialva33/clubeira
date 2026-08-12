defmodule ClubeiraWeb.PartnerAuth do
  @moduledoc """
  Authenticates the partner browser surface and re-derives its current access.

  A tenant `partner_manager` role is necessary but not sufficient. Each polo
  retained here must also contain at least one place backed by the current
  global organization, operator and staff affiliations used by the domain.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  use Gettext, backend: ClubeiraWeb.Gettext

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Directory
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope

  @session_key "backoffice_session_token"

  @type access :: %{polos: [map()]}

  @spec authorize(AccountScope.t()) :: {:ok, access()} | {:error, :forbidden | term()}
  def authorize(%AccountScope{} = account_scope) do
    with {:ok, actor_access} <- Polos.get_actor_access(account_scope),
         {:ok, polos} <- retain_assigned_polos(actor_access.polos, account_scope) do
      if polos == [], do: {:error, :forbidden}, else: {:ok, %{polos: polos}}
    end
  end

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    locale = Map.get(session, "locale", "pt_BR")
    Gettext.put_locale(ClubeiraWeb.Gettext, locale)

    with token when is_binary(token) <- Map.get(session, @session_key),
         {:ok, account_scope} <-
           Accounts.fetch_scope_by_api_token(token, RequestContext.new!()),
         {:ok, access} <- authorize(account_scope) do
      {:cont,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:partner_access, access)
       |> assign(:locale, locale)}
    else
      _invalid_or_forbidden ->
        {:halt,
         socket
         |> put_flash(
           :error,
           gettext("Your session has expired or does not have partner access.")
         )
         |> redirect(to: "/partner/login")}
    end
  end

  defp retain_assigned_polos(polos, account_scope) do
    polos
    |> Enum.filter(&(:manage_own_places in &1.capabilities))
    |> Enum.reduce_while({:ok, []}, fn polo, {:ok, assigned} ->
      scope =
        Scope.new!(polo.id,
          actor_user_id: account_scope.user.id,
          request_id: account_scope.request_id,
          roles: polo.roles
        )

      case Directory.list_partner_places(scope, %{"limit" => "1"}) do
        {:ok, %{places: []}} -> {:cont, {:ok, assigned}}
        {:ok, %{places: [_place | _rest]}} -> {:cont, {:ok, [polo | assigned]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_polos()
  end

  defp reverse_polos({:ok, polos}), do: {:ok, Enum.reverse(polos)}
  defp reverse_polos({:error, _reason} = error), do: error
end
