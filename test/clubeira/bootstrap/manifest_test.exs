defmodule Clubeira.Bootstrap.ManifestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Bootstrap.Manifest

  test "validates and normalizes a production bootstrap manifest" do
    attributes = valid_manifest()
    assert {:ok, manifest} = Manifest.new(attributes)
    assert Manifest.new!(attributes) == manifest

    assert manifest.city.country_code == "BR"
    assert manifest.polo.slug == "sobral"
    assert manifest.legal.locale == "pt-BR"
    assert manifest.billing.provider_code == "mercado_pago"
    assert manifest.admin_email == "admin@clubeira.example"
    assert manifest.legal.effective_from == ~U[2026-08-08 12:00:00.000000Z]
    assert manifest.billing.valid_from == ~U[2026-08-08 12:00:00.000000Z]
  end

  test "rejects unknown keys and unsafe legal content locations" do
    assert {:error, {:invalid_manifest, "root", :unknown_keys}} =
             valid_manifest()
             |> Map.put("typo", true)
             |> Manifest.new()

    assert {:error, {:invalid_manifest, "legal.content_uri", :absolute_https_url_required}} =
             valid_manifest()
             |> put_in(["legal", "content_uri"], "http://clubeira.example/terms/v1")
             |> Manifest.new()

    assert {:error, {:invalid_manifest, "legal.content_file", :absolute_regular_file_required}} =
             valid_manifest()
             |> put_in(["legal", "content_file"], "priv/static/legal/terms.txt")
             |> Manifest.new()
  end

  test "rejects malformed root, missing keys and non-map sections" do
    assert {:error, {:invalid_manifest, "root", :map_required}} = Manifest.new(:invalid)

    assert {:error, {:invalid_manifest, "root", {:missing_keys, ["billing"]}}} =
             valid_manifest() |> Map.delete("billing") |> Manifest.new()

    for section <- ~w(city polo legal billing) do
      assert {:error, {:invalid_manifest, ^section, :map_required}} =
               valid_manifest() |> Map.put(section, :invalid) |> Manifest.new()
    end
  end

  test "new!/1 raises a contextual error for an invalid manifest" do
    assert_raise ArgumentError,
                 ~r/invalid production bootstrap manifest at root: :unknown_keys/,
                 fn ->
                   valid_manifest() |> Map.put(:unknown, true) |> Manifest.new!()
                 end
  end

  test "requires stable UUIDv7 identities" do
    for {field, value} <- [
          {"operation_id", Ecto.UUID.generate()},
          {"polo_id", "not-a-uuid"}
        ] do
      assert {:error, {:invalid_manifest, ^field, :uuidv7_required}} =
               valid_manifest() |> Map.put(field, value) |> Manifest.new()
    end
  end

  test "validates normalized city and polo identities" do
    invalids = [
      {"city.country_code", :iso_3166_alpha2_required,
       &put_in(&1, ["city", "country_code"], "BRA")},
      {"city.country_code", :string_required, &put_in(&1, ["city", "country_code"], 55)},
      {"polo.slug", :slug_required, &put_in(&1, ["polo", "slug"], "não válido")},
      {"polo.slug", :string_required, &put_in(&1, ["polo", "slug"], nil)},
      {"city.name", :invalid_length, &put_in(&1, ["city", "name"], "")},
      {"city.external_code", :string_required, &put_in(&1, ["city", "external_code"], 2_312_908)},
      {"city.timezone", :iana_timezone_required, &put_in(&1, ["city", "timezone"], "UTC")}
    ]

    for {path, reason, mutate} <- invalids do
      assert {:error, {:invalid_manifest, ^path, ^reason}} =
               valid_manifest() |> mutate.() |> Manifest.new()
    end
  end

  test "validates legal and billing versioned inputs" do
    invalids = [
      {"legal.code", :identifier_required, &put_in(&1, ["legal", "code"], "Invalid code")},
      {"billing.provider_code", :string_required, &put_in(&1, ["billing", "provider_code"], nil)},
      {"legal.locale", :locale_required, &put_in(&1, ["legal", "locale"], "pt BR")},
      {"legal.version", :initial_version_required, &put_in(&1, ["legal", "version"], 2)},
      {"legal.content_uri", :absolute_https_url_required,
       &put_in(&1, ["legal", "content_uri"], :invalid)},
      {"legal.effective_from", :iso8601_datetime_required,
       &put_in(&1, ["legal", "effective_from"], "tomorrow")},
      {"billing.valid_from", :iso8601_datetime_required,
       &put_in(&1, ["billing", "valid_from"], nil)}
    ]

    for {path, reason, mutate} <- invalids do
      assert {:error, {:invalid_manifest, ^path, ^reason}} =
               valid_manifest() |> mutate.() |> Manifest.new()
    end
  end

  test "admin email is optional, normalized and validated" do
    assert {:ok, %{admin_email: nil}} =
             valid_manifest() |> Map.delete("admin_email") |> Manifest.new()

    for invalid <- ["invalid", 123] do
      assert {:error, {:invalid_manifest, "admin_email", :email_required}} =
               valid_manifest() |> Map.put("admin_email", invalid) |> Manifest.new()
    end
  end

  test "fingerprint excludes the deployment-specific content mount" do
    assert {:ok, manifest} = Manifest.new(valid_manifest())
    relocated = %{manifest | legal: Map.put(manifest.legal, :content_file, "/another/mount")}

    assert Manifest.fingerprint(relocated) == Manifest.fingerprint(manifest)
  end

  defp valid_manifest do
    %{
      "operation_id" => Ecto.UUID.generate(version: 7),
      "polo_id" => Ecto.UUID.generate(version: 7),
      "city" => %{
        "country_code" => "br",
        "subdivision_code" => "CE",
        "external_code" => "2312908",
        "name" => "Sobral",
        "timezone" => "America/Fortaleza"
      },
      "polo" => %{
        "name" => "Clubeira Sobral",
        "slug" => "Sobral",
        "timezone" => "America/Fortaleza"
      },
      "legal" => %{
        "code" => "consumer-terms",
        "locale" => "pt-BR",
        "version" => 1,
        "content_uri" => "https://clubeira.example/legal/consumer-terms-v1.txt",
        "content_file" => legal_content_file(),
        "effective_from" => "2026-08-08T09:00:00-03:00"
      },
      "billing" => %{
        "provider_code" => "mercado_pago",
        "provider_name" => "Mercado Pago",
        "merchant_account_name" => "Clubeira Sobral",
        "merchant_account_reference" => "clubeira-sobral",
        "valid_from" => "2026-08-08T09:00:00-03:00"
      },
      "admin_email" => " ADMIN@Clubeira.Example "
    }
  end

  defp legal_content_file do
    Application.app_dir(:clubeira, "priv/static/legal/demo-consumer-terms-v1.txt")
  end
end
