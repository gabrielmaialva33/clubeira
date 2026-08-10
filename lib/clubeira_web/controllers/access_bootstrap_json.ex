defmodule ClubeiraWeb.AccessBootstrapJSON do
  @moduledoc false

  def show(%{access: access}) do
    %{
      data: %{
        platform: access_scope_data(access.platform),
        polos: Enum.map(access.polos, &polo_access_data/1)
      }
    }
  end

  defp access_scope_data(scope) do
    %{
      roles: scope.roles,
      capabilities: Enum.map(scope.capabilities, &Atom.to_string/1)
    }
  end

  defp polo_access_data(access) do
    %{
      id: access.id,
      slug: access.slug,
      name: access.name,
      timezone: access.timezone,
      status: access.status,
      roles: access.roles,
      capabilities: Enum.map(access.capabilities, &Atom.to_string/1)
    }
  end
end
