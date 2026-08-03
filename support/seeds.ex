defmodule Clubeira.Seeds do
  @moduledoc """
  Entry point for deterministic development seed scenarios.

  Seed data is written atomically. Tenant-scoped writes always set the polo
  context transaction-locally so the same code works with non-bypass RLS roles.
  """

  alias Clubeira.Repo
  alias Clubeira.Seeds.Demo
  alias Clubeira.Tenancy.Scope

  @spec run!() :: map()
  def run! do
    case Repo.transact(fn -> {:ok, Demo.run!()} end, timeout: :infinity) do
      {:ok, summary} -> summary
      {:error, reason} -> raise "could not seed Clubeira demo data: #{inspect(reason)}"
    end
  end

  @spec with_polo!(Ecto.UUID.t(), (-> result)) :: result when result: var
  def with_polo!(polo_id, fun) when is_binary(polo_id) and is_function(fun, 0) do
    scope = Scope.new!(polo_id)

    case Repo.transact_in_polo(scope, fn -> {:ok, fun.()} end) do
      {:ok, result} -> result
      {:error, reason} -> raise "could not seed polo #{polo_id}: #{inspect(reason)}"
    end
  end
end
