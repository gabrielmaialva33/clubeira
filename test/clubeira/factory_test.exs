defmodule Clubeira.FactoryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Factory
  alias Clubeira.Factory.Brazil

  test "generates unique deterministic values for constrained fields" do
    assert first_email = Factory.unique_email()
    assert second_email = Factory.unique_email()
    assert first_email != second_email
    assert String.ends_with?(first_email, "@example.test")

    assert first_slug = Factory.unique_slug("polo")
    assert second_slug = Factory.unique_slug("polo")
    assert first_slug != second_slug
    assert String.starts_with?(first_slug, "polo-")

    assert first_cpf = Factory.cpf()
    assert second_cpf = Factory.cpf()
    assert first_cpf != second_cpf
    assert first_cpf =~ ~r/^\d{11}$/

    assert first_cnpj = Factory.cnpj()
    assert second_cnpj = Factory.cnpj()
    assert first_cnpj != second_cnpj
    assert first_cnpj =~ ~r/^\d{14}$/
  end

  test "generates Brazilian presentation data" do
    assert name = Factory.person_name()
    assert is_binary(name)
    assert String.trim(name) != ""
  end

  test "generates valid and repeatable CPF numbers" do
    assert Brazil.cpf(0) == "98000000032"
    assert Brazil.cpf(1) == "98000000113"
    assert Brazil.cpf(1) == Brazil.cpf(1)
    assert Brazil.cpf(1) != Brazil.cpf(2)
  end

  test "generates valid and repeatable CNPJ numbers" do
    assert Brazil.cnpj(0) == "10000000000145"
    assert Brazil.cnpj(1) == "10000001000190"
    assert Brazil.cnpj(1) == Brazil.cnpj(1)
    assert Brazil.cnpj(1) != Brazil.cnpj(2)
  end
end
