# The migrator connects before extensions exist. A dedicated type module keeps
# that incomplete Postgrex cache from leaking into the concurrent runtime repo.
Postgrex.Types.define(Clubeira.ConcurrencyMigrationTypes, [])
