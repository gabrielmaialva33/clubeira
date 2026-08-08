defmodule Clubeira.Bootstrap.ManifestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Bootstrap.Manifest

  test "validates and normalizes a production bootstrap manifest" do
    assert {:ok, manifest} = Manifest.new(valid_manifest())

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
