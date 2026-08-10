defmodule Clubeira.Polos do
  @moduledoc """
  Public routing and tenant-boundary operations for polos.
  """

  alias Clubeira.Accounts.Scope, as: AccountScope
  alias Clubeira.Polos.ActorAccessReader
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Polos.PublicDirectoryReader
  alias Clubeira.Repo

  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @spec get_actor_access(AccountScope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_actor_access(account_scope), to: ActorAccessReader, as: :get

  @spec list_public(map()) ::
          {:ok, %{polos: [map()], page: map()}} | {:error, :invalid_pagination | term()}
  defdelegate list_public(params), to: PublicDirectoryReader, as: :list

  @spec resolve_route(String.t()) :: {:ok, PoloRoute.t()} | {:error, :polo_not_found}
  def resolve_route(slug) when is_binary(slug) do
    if valid_slug?(slug) do
      case Repo.get_by(PoloRoute, slug: slug) do
        %PoloRoute{} = route -> {:ok, route}
        nil -> {:error, :polo_not_found}
      end
    else
      {:error, :polo_not_found}
    end
  end

  def resolve_route(_slug), do: {:error, :polo_not_found}

  defp valid_slug?(slug) do
    byte_size(slug) in 2..80 and Regex.match?(@slug_pattern, slug)
  end
end
