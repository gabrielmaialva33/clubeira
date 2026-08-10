defmodule Clubeira.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Clubeira.RuntimeConfig

  @environment_variables ~w(
    CLUBEIRA_PIX_PROVIDER DATABASE_CA_CERT_FILE DATABASE_SSL PHX_HOST
    PLATFORM_BILLING_MERCHANT_ACCOUNT_ID POOL_SIZE REVIEW_MEDIA_PUBLIC_BASE_URL
  )

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

  test "uuid!/1 validates configured database identities" do
    System.delete_env("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID")

    assert_raise RuntimeError,
                 ~r/environment variable PLATFORM_BILLING_MERCHANT_ACCOUNT_ID is required/,
                 fn ->
                   RuntimeConfig.uuid!("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID")
                 end

    System.put_env("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID", "not-a-uuid")

    assert_raise RuntimeError,
                 ~r/PLATFORM_BILLING_MERCHANT_ACCOUNT_ID must be a UUID/,
                 fn ->
                   RuntimeConfig.uuid!("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID")
                 end

    id = Ecto.UUID.generate(version: 7)
    System.put_env("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID", id)
    assert RuntimeConfig.uuid!("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID") == id
  end

  test "absolute_https_url!/1 accepts only credential-free HTTPS endpoints" do
    for invalid <- [
          "http://storage.example.test/media",
          "https://token@storage.example.test/media",
          "https://storage.example.test/media#fragment",
          "/relative/media"
        ] do
      System.put_env("REVIEW_MEDIA_PUBLIC_BASE_URL", invalid)

      assert_raise RuntimeError,
                   ~r/REVIEW_MEDIA_PUBLIC_BASE_URL must be an absolute HTTPS URL/,
                   fn ->
                     RuntimeConfig.absolute_https_url!("REVIEW_MEDIA_PUBLIC_BASE_URL")
                   end
    end

    System.put_env("REVIEW_MEDIA_PUBLIC_BASE_URL", "https://cdn.example.test/reviews")

    assert RuntimeConfig.absolute_https_url!("REVIEW_MEDIA_PUBLIC_BASE_URL") ==
             "https://cdn.example.test/reviews"
  end

  test "provider_code!/1 accepts canonical registry keys and rejects unsafe values" do
    for invalid <- ["Stripe", "stripe/payment", " stripe", String.duplicate("a", 64)] do
      System.put_env("CLUBEIRA_PIX_PROVIDER", invalid)

      assert_raise RuntimeError,
                   ~r/CLUBEIRA_PIX_PROVIDER must be a lowercase provider code/,
                   fn ->
                     RuntimeConfig.provider_code!("CLUBEIRA_PIX_PROVIDER")
                   end
    end

    System.put_env("CLUBEIRA_PIX_PROVIDER", "stripe_connect")
    assert RuntimeConfig.provider_code!("CLUBEIRA_PIX_PROVIDER") == "stripe_connect"
  end
end
