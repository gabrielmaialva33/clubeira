defmodule ClubeiraWeb.OpenAPIContractTest do
  use ExUnit.Case, async: true

  @spec_path "priv/static/openapi/v1.json"
  @http_methods ~w(delete get patch post put)

  test "published OpenAPI contract covers every v1 API operation" do
    documented_operations =
      open_api()
      |> Map.fetch!("paths")
      |> Enum.flat_map(fn {path, path_item} ->
        for method <- @http_methods, Map.has_key?(path_item, method), do: {method, path}
      end)
      |> MapSet.new()

    routed_operations =
      ClubeiraWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1"))
      |> Enum.map(fn route ->
        {route.verb |> Atom.to_string() |> String.downcase(), open_api_path(route.path)}
      end)
      |> MapSet.new()

    assert documented_operations == routed_operations
  end

  test "published operations expose stable client metadata and a successful outcome" do
    operations =
      for {path, path_item} <- open_api()["paths"],
          method <- @http_methods,
          operation = path_item[method],
          operation,
          do: {method, path, operation}

    operation_ids =
      Enum.map(operations, fn {_method, _path, operation} -> operation["operationId"] end)

    assert Enum.all?(operation_ids, &(is_binary(&1) and &1 != ""))
    assert length(operation_ids) == MapSet.size(MapSet.new(operation_ids))

    for {method, path, operation} <- operations do
      assert is_binary(operation["summary"]) and operation["summary"] != "",
             "#{method} #{path} must have a summary"

      assert is_list(operation["tags"]) and operation["tags"] != [],
             "#{method} #{path} must have at least one tag"

      assert Enum.any?(Map.keys(operation["responses"]), &String.match?(&1, ~r/^[23]\d\d$/)),
             "#{method} #{path} must document a 2xx or explicit 3xx success"
    end
  end

  defp open_api do
    @spec_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp open_api_path(path), do: Regex.replace(~r/:([a-zA-Z0-9_]+)/, path, "{\\1}")
end
