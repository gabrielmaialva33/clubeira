defmodule Clubeira.Platform.SubscriptionOptionsReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Platform.Feature
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PlanVersionFeature
  alias Clubeira.Platform.Price
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{actor_user_id: nil}), do: {:error, :billing_admin_required}

  def list(%Scope{} = scope) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_billing, now) do
        {:ok, options(repo, now)}
      end
    end)
  end

  def list(_scope), do: {:error, :billing_admin_required}

  defp options(repo, now) do
    rows =
      Price
      |> join(:inner, [price], version in PlanVersion,
        on: version.id == price.platform_plan_version_id
      )
      |> join(:inner, [_price, version], plan in Plan, on: plan.id == version.platform_plan_id)
      |> where(
        [price, version, plan],
        plan.status == "active" and version.status == "published" and price.currency == "BRL" and
          price.amount > 0 and price.billing_interval_unit in ["month", "year"]
      )
      |> where(
        [price],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          price.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> order_by([price, version, plan],
        asc: plan.name,
        desc: version.version,
        asc: price.currency,
        asc: price.id
      )
      |> select([price, version, plan], %{price: price, version: version, plan: plan})
      |> repo.all()

    features_by_version = features_by_version(repo, Enum.map(rows, & &1.version.id))

    Enum.map(rows, fn row ->
      %{
        plan: %{id: row.plan.id, code: row.plan.code, name: row.plan.name},
        version: %{
          id: row.version.id,
          version: row.version.version,
          name: row.version.name,
          description: row.version.description,
          features: Map.get(features_by_version, row.version.id, [])
        },
        price: %{
          id: row.price.id,
          currency: row.price.currency,
          amount: row.price.amount,
          billing_interval_unit: row.price.billing_interval_unit,
          billing_interval_count: row.price.billing_interval_count,
          valid_during: row.price.valid_during
        }
      }
    end)
  end

  defp features_by_version(_repo, []), do: %{}

  defp features_by_version(repo, version_ids) do
    PlanVersionFeature
    |> join(:inner, [assignment], feature in Feature,
      on:
        feature.id == assignment.platform_feature_id and
          feature.value_kind == assignment.value_kind
    )
    |> where([assignment], assignment.platform_plan_version_id in ^version_ids)
    |> order_by([assignment, feature],
      asc: assignment.platform_plan_version_id,
      asc: feature.key
    )
    |> select([assignment, feature], %{
      version_id: assignment.platform_plan_version_id,
      key: feature.key,
      name: feature.name,
      value_kind: assignment.value_kind,
      boolean_value: assignment.boolean_value,
      integer_value: assignment.integer_value
    })
    |> repo.all()
    |> Enum.group_by(& &1.version_id, &Map.delete(&1, :version_id))
  end

  defp fetch_active_polo(repo, polo_id) do
    case repo.one(from(polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE")) do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
