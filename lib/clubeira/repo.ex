defmodule Clubeira.Repo do
  @moduledoc """
  Ecto repository and transaction boundary for Clubeira.

  Tenant-scoped domain operations must use `transact_in_polo/3` so PostgreSQL
  row-level security receives transaction-local scope metadata.
  """

  use Ecto.Repo,
    otp_app: :clubeira,
    adapter: Ecto.Adapters.Postgres

  alias Clubeira.Tenancy.Scope

  @scope_query """
  SELECT
    current_setting('app.current_polo_id', true),
    current_setting('app.current_actor_user_id', true),
    current_setting('app.current_request_id', true)
  """

  @set_scope_query """
  SELECT
    set_config('app.current_polo_id', $1, true),
    set_config('app.current_actor_user_id', $2, true),
    set_config('app.current_request_id', $3, true)
  """

  @type transaction_result(result) :: {:ok, result} | {:error, term()}

  @doc """
  Runs a domain operation with transaction-local polo and actor metadata.

  Nested operations may reuse the same scope, but switching polo, actor, or
  request inside an existing scoped transaction fails closed.
  """
  @spec transact_in_polo(
          Scope.t(),
          (-> transaction_result(result)) | (module() -> transaction_result(result)),
          keyword()
        ) :: transaction_result(result)
        when result: var
  def transact_in_polo(scope, operation, options \\ [])

  def transact_in_polo(%Scope{} = scope, operation, options)
      when is_function(operation, 0) or is_function(operation, 1) do
    if in_transaction?() do
      run_in_scope(__MODULE__, scope, operation)
    else
      transact(
        fn repo -> run_in_scope(repo, scope, operation) end,
        options
      )
    end
  end

  def transact_in_polo(_scope, _operation, _options), do: {:error, :invalid_tenant_scope}

  defp run_in_scope(repo, scope, operation) do
    previous = current_scope_settings(repo)

    with {:ok, active} <- merge_scope(previous, scope),
         :ok <- put_scope_settings(repo, active) do
      try do
        invoke(operation, repo)
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          restore_scope_after_failure(repo, previous)
          :erlang.raise(kind, reason, stacktrace)
      else
        result ->
          :ok = put_scope_settings(repo, previous)
          result
      end
    end
  end

  defp restore_scope_after_failure(repo, previous) do
    put_scope_settings(repo, previous)
  rescue
    error in Postgrex.Error ->
      if transaction_aborted?(error) do
        # PostgreSQL will discard transaction-local settings on rollback.
        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  defp transaction_aborted?(%Postgrex.Error{postgres: %{code: code}}) do
    code in [:in_failed_sql_transaction, "25P02"]
  end

  defp transaction_aborted?(_error), do: false

  defp current_scope_settings(repo) do
    %{rows: [[polo_id, actor_user_id, request_id]]} = repo.query!(@scope_query)

    %{
      polo_id: normalize_setting(polo_id),
      actor_user_id: normalize_setting(actor_user_id),
      request_id: normalize_setting(request_id)
    }
  end

  defp merge_scope(previous, scope) do
    requested = %{
      polo_id: scope.polo_id,
      actor_user_id: scope.actor_user_id,
      request_id: scope.request_id
    }

    Enum.reduce_while(requested, {:ok, %{}}, fn {key, value}, {:ok, merged} ->
      case merge_setting(Map.fetch!(previous, key), value) do
        {:ok, setting} -> {:cont, {:ok, Map.put(merged, key, setting)}}
        :scope_mismatch -> {:halt, {:error, {:tenant_scope_mismatch, key}}}
      end
    end)
  end

  defp merge_setting("", nil), do: {:ok, ""}
  defp merge_setting("", requested), do: {:ok, requested}
  defp merge_setting(previous, nil), do: {:ok, previous}
  defp merge_setting(value, value), do: {:ok, value}
  defp merge_setting(_previous, _requested), do: :scope_mismatch

  defp put_scope_settings(repo, settings) do
    repo.query!(@set_scope_query, [
      settings.polo_id,
      settings.actor_user_id,
      settings.request_id
    ])

    :ok
  end

  defp invoke(operation, _repo) when is_function(operation, 0), do: operation.()
  defp invoke(operation, repo) when is_function(operation, 1), do: operation.(repo)

  defp normalize_setting(nil), do: ""
  defp normalize_setting(value), do: value
end
