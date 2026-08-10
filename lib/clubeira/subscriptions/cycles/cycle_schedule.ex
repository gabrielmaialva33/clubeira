defmodule Clubeira.Subscriptions.CycleSchedule do
  @moduledoc """
  Computes bounded benefit windows in the polo's IANA time zone.

  PostgreSQL performs the wall-clock arithmetic so month/year boundaries and
  daylight-saving transitions use the same time-zone catalog that validates
  persisted polos.
  """

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.ProductOfferingVersion

  @type error_reason :: :unsupported_cycle_policy | :invalid_cycle_interval

  @spec bounds(module(), ProductOfferingVersion.t(), Polo.t(), DateTime.t()) ::
          {:ok, Postgrex.Range.t()} | {:error, error_reason()}
  def bounds(repo, %ProductOfferingVersion{} = version, %Polo{} = polo, starts_at) do
    with :ok <- validate_policy(version.cycle_policy),
         {:ok, expression} <- interval_expression(version.cycle_interval_unit),
         :ok <- validate_interval_count(version.cycle_interval_count),
         {:ok, {lower, upper}} <-
           calculate_bounds(
             repo,
             version.cycle_policy,
             expression,
             starts_at,
             version.cycle_interval_count,
             polo.timezone
           ) do
      {:ok,
       %Postgrex.Range{
         lower: lower,
         upper: upper,
         lower_inclusive: true,
         upper_inclusive: false
       }}
    end
  end

  defp calculate_bounds(repo, "calendar", expression, starts_at, count, timezone) do
    truncation = truncation(expression)

    sql = """
    SELECT
      (date_trunc('#{truncation}', $1::timestamptz AT TIME ZONE $3) AT TIME ZONE $3),
      (
        date_trunc('#{truncation}', $1::timestamptz AT TIME ZONE $3) + #{expression}
      ) AT TIME ZONE $3
    """

    {:ok, query_bounds(repo, sql, starts_at, count, timezone)}
  end

  defp calculate_bounds(repo, "anniversary", expression, starts_at, count, timezone) do
    sql = """
    SELECT
      $1::timestamptz,
      (($1::timestamptz AT TIME ZONE $3) + #{expression}) AT TIME ZONE $3
    """

    {:ok, query_bounds(repo, sql, starts_at, count, timezone)}
  end

  defp calculate_bounds(_repo, _policy, _expression, _starts_at, _count, _timezone) do
    {:error, :unsupported_cycle_policy}
  end

  defp query_bounds(repo, sql, starts_at, count, timezone) do
    %{rows: [[lower, upper]]} = repo.query!(sql, [starts_at, count, timezone])
    {lower, upper}
  end

  defp interval_expression("day"), do: {:ok, "make_interval(days => $2)"}
  defp interval_expression("month"), do: {:ok, "make_interval(months => $2)"}
  defp interval_expression("year"), do: {:ok, "make_interval(years => $2)"}
  defp interval_expression(_unit), do: {:error, :invalid_cycle_interval}

  defp validate_policy(policy) when policy in ["calendar", "anniversary"], do: :ok
  defp validate_policy(_policy), do: {:error, :unsupported_cycle_policy}

  defp truncation("make_interval(days => $2)"), do: "day"
  defp truncation("make_interval(months => $2)"), do: "month"
  defp truncation("make_interval(years => $2)"), do: "year"

  defp validate_interval_count(count) when is_integer(count) and count > 0, do: :ok
  defp validate_interval_count(_count), do: {:error, :invalid_cycle_interval}
end
