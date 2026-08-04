pool_size = Application.fetch_env!(:clubeira, Clubeira.Repo) |> Keyword.fetch!(:pool_size)

ExUnit.start(max_cases: pool_size)
Ecto.Adapters.SQL.Sandbox.mode(Clubeira.Repo, :manual)
