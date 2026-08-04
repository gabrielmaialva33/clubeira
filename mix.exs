defmodule Clubeira.MixProject do
  use Mix.Project

  def project do
    [
      app: :clubeira,
      version: "0.1.0",
      elixir: "~> 1.19.5",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_file: {:no_warn, "priv/plts/clubeira.plt"}
      ],
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Clubeira.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, quality: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:dev), do: ["lib", "support"]
  defp elixirc_paths(:test), do: ["lib", "support", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:argon2_elixir, "~> 4.1"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8.2", only: [:dev, :test]},
      {:faker, "~> 0.19.0", only: [:dev, :test]},
      {:mix_audit, "~> 2.1.5", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "db.setup", "assets.setup", "assets.build"],
      "db.setup": [
        "cmd docker compose up -d --wait postgres",
        "cmd env CLUBEIRA_DATABASE_ROLE_MODE=migrator mix ecto.setup"
      ],
      "db.migrate": [
        "cmd docker compose up -d --wait postgres",
        "cmd env CLUBEIRA_DATABASE_ROLE_MODE=migrator mix ecto.migrate"
      ],
      "db.reset": [
        "cmd docker compose up -d --wait postgres",
        "cmd env CLUBEIRA_DATABASE_ROLE_MODE=migrator mix ecto.reset"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.rollback --all", "ecto.migrate", "run priv/repo/seeds.exs"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind clubeira", "esbuild clubeira"],
      "assets.deploy": [
        "tailwind clubeira --minify",
        "esbuild clubeira --minify",
        "phx.digest"
      ],
      lint: ["format --check-formatted", "credo --strict"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "credo --strict",
        "cmd mix hex.audit",
        "deps.audit",
        "sobelow --config",
        "test"
      ],
      precommit: ["format", "quality"]
    ]
  end
end
