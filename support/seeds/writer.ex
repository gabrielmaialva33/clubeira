defmodule Clubeira.Seeds.Writer do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Repo

  @spec upsert!(atom(), map(), [atom()], keyword()) :: Ecto.Schema.t()
  def upsert!(factory, attributes, replace_fields, options \\ []) do
    conflict_target = Keyword.get(options, :conflict_target, [:id])

    Factory.insert(factory, attributes,
      conflict_target: conflict_target,
      on_conflict: {:replace, replace_fields},
      returning: true
    )
  end

  @spec insert_once!(atom(), map()) :: Ecto.Schema.t()
  def insert_once!(factory, attributes) do
    record = Factory.insert(factory, attributes, on_conflict: :nothing)
    primary_key = record.__struct__.__schema__(:primary_key)
    lookup = Map.take(record, primary_key)

    Repo.get_by!(record.__struct__, lookup)
  end
end
