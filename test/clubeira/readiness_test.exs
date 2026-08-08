defmodule Clubeira.ReadinessTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Readiness

  @pending_version 20_990_101_000_000

  test "reports migration files that are not present in schema_migrations" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "clubeira-readiness-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)

    File.write!(
      Path.join(directory, "#{@pending_version}_readiness_probe.exs"),
      "defmodule ReadinessProbe do\nend\n"
    )

    on_exit(fn -> File.rm_rf!(directory) end)

    assert Readiness.check(migration_directories: [directory]) ==
             {:error, {:pending_migrations, [@pending_version]}}
  end
end
