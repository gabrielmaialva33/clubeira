%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "support/",
          "test/",
          "priv/repo/seeds.exs"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          ~r"/priv/repo/migrations/"
        ]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5_000,
      color: true,
      checks: %{
        extra: [
          {Credo.Check.Refactor.UtcNowTruncate, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ],
        disabled: []
      }
    }
  ]
}
