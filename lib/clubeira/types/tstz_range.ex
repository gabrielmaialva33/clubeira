defmodule Clubeira.Types.TstzRange do
  @moduledoc """
  Ecto type for PostgreSQL `tstzrange` values.

  Business constraints such as boundedness and `[)` semantics remain enforced
  by each table's database constraints.
  """

  use Ecto.Type

  @impl true
  def type, do: :tstzrange

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(%Postgrex.Range{} = range), do: validate(range)
  def cast(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(%Postgrex.Range{} = range), do: validate(range)
  def load(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(%Postgrex.Range{} = range), do: validate(range)
  def dump(_value), do: :error

  defp validate(%Postgrex.Range{lower: lower, upper: upper} = range) do
    if valid_bound?(lower) and valid_bound?(upper), do: {:ok, range}, else: :error
  end

  defp valid_bound?(:unbound), do: true
  defp valid_bound?(:empty), do: true
  defp valid_bound?(%DateTime{}), do: true
  defp valid_bound?(_bound), do: false
end
