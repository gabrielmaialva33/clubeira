defmodule Clubeira.Platform.PlanReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Platform.Feature
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PlanVersionFeature
  alias Clubeira.Platform.Price
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @spec list(ActorScope.t()) :: {:ok, [map()]} | {:error, :invalid_actor_scope}
  def list(%ActorScope{} = scope) do
    Repo.transact_as_actor(scope, fn repo ->
      now = transaction_time(repo)

      plans =
        repo.all(
          from(plan in Plan,
            where: plan.status == "active",
            order_by: [asc: plan.code],
            lock: "FOR SHARE"
          )
        )

      {:ok,
       plans
       |> Enum.map(&latest_published_view(repo, &1, now))
       |> Enum.reject(&is_nil/1)}
    end)
  end

  def list(_scope), do: {:error, :invalid_actor_scope}

  @spec persisted_view(module(), Plan.t(), PlanVersion.t()) :: map()
  def persisted_view(repo, plan, version) do
    price =
      Price
      |> where([price], price.platform_plan_version_id == ^version.id)
      |> order_by([price], asc: price.currency, asc: price.id)
      |> repo.one!()

    render_view(repo, plan, version, price)
  end

  defp render_view(repo, plan, version, price) do
    features =
      repo.all(
        from(assignment in PlanVersionFeature,
          join: feature in Feature,
          on:
            feature.id == assignment.platform_feature_id and
              feature.value_kind == assignment.value_kind,
          where: assignment.platform_plan_version_id == ^version.id,
          order_by: [asc: feature.key],
          select: %{
            key: feature.key,
            name: feature.name,
            value_kind: assignment.value_kind,
            boolean_value: assignment.boolean_value,
            integer_value: assignment.integer_value
          }
        )
      )

    %{
      id: plan.id,
      code: plan.code,
      name: plan.name,
      status: plan.status,
      version: %{
        id: version.id,
        version: version.version,
        name: version.name,
        description: version.description,
        status: version.status,
        published_at: version.published_at,
        features: features,
        price: %{
          id: price.id,
          currency: price.currency,
          amount: price.amount,
          billing_interval_unit: price.billing_interval_unit,
          billing_interval_count: price.billing_interval_count,
          valid_during: price.valid_during
        }
      }
    }
  end

  defp latest_published_view(repo, plan, now) do
    version_and_price =
      repo.one(
        from(version in PlanVersion,
          join: price in Price,
          on:
            price.platform_plan_version_id == version.id and
              fragment(
                "? @> (? AT TIME ZONE 'UTC')",
                price.valid_during,
                type(^now, :utc_datetime_usec)
              ),
          where: version.platform_plan_id == ^plan.id and version.status == "published",
          order_by: [desc: version.version, asc: price.currency, asc: price.id],
          select: {version, price},
          limit: 1,
          lock: "FOR SHARE"
        )
      )

    case version_and_price do
      {version, price} -> render_view(repo, plan, version, price)
      nil -> nil
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
