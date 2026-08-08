defmodule Clubeira.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Clubeira.RuntimeConfig

  @environment_variables ~w(DATABASE_CA_CERT_FILE DATABASE_SSL PHX_HOST POOL_SIZE)

  setup do
    previous_values = Map.new(@environment_variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "integer_in_range!/3 names invalid and out-of-range values" do
    System.put_env("POOL_SIZE", "many")

    assert_raise RuntimeError, ~r/POOL_SIZE must be an integer in 1\.\.100/, fn ->
      RuntimeConfig.integer_in_range!("POOL_SIZE", 10, 1..100)
    end

    System.put_env("POOL_SIZE", "101")

    assert_raise RuntimeError, ~r/POOL_SIZE must be an integer in 1\.\.100/, fn ->
      RuntimeConfig.integer_in_range!("POOL_SIZE", 10, 1..100)
    end
  end

  test "host!/1 requires a bare hostname" do
    System.delete_env("PHX_HOST")

    assert_raise RuntimeError, ~r/environment variable PHX_HOST is required/, fn ->
      RuntimeConfig.host!("PHX_HOST")
    end

    for invalid <- ["https://api.example.com", "api.example.com/path", "user@api.example.com"] do
      System.put_env("PHX_HOST", invalid)

      assert_raise RuntimeError,
                   ~r/PHX_HOST must be a hostname without scheme, credentials, or path/,
                   fn ->
                     RuntimeConfig.host!("PHX_HOST")
                   end
    end

    System.put_env("PHX_HOST", "api.clubeira.com.br")
    assert RuntimeConfig.host!("PHX_HOST") == "api.clubeira.com.br"
  end

  test "database_ssl!/0 verifies peers by default and permits an explicit local opt-out" do
    System.delete_env("DATABASE_SSL")
    System.delete_env("DATABASE_CA_CERT_FILE")
    assert RuntimeConfig.database_ssl!() == true

    System.put_env("DATABASE_SSL", "false")
    assert RuntimeConfig.database_ssl!() == false
  end

  test "database_ssl!/0 rejects a missing custom CA file" do
    System.put_env("DATABASE_SSL", "true")
    System.put_env("DATABASE_CA_CERT_FILE", "/missing/clubeira-ca.pem")

    assert_raise RuntimeError,
                 ~r/DATABASE_CA_CERT_FILE must point to a readable regular file/,
                 fn ->
                   RuntimeConfig.database_ssl!()
                 end
  end
end
