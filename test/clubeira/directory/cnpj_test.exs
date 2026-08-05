defmodule Clubeira.Directory.CnpjTest do
  use ExUnit.Case, async: true

  alias Clubeira.Directory.Cnpj
  alias Clubeira.Factory.Brazil

  test "normalizes and validates the official alphanumeric example" do
    assert Cnpj.normalize("12.Abc.345/01de-35") == {:ok, "12ABC34501DE35"}
  end

  test "keeps existing numeric CNPJ identifiers valid" do
    cnpj = Brazil.cnpj(42)
    assert Cnpj.normalize(cnpj) == {:ok, cnpj}
  end

  test "rejects invalid check digits and non-ASCII characters" do
    assert Cnpj.normalize("12.ABC.345/01DE-34") == {:error, :invalid_cnpj}
    assert Cnpj.normalize("12.ABÇ.345/01DE-35") == {:error, :invalid_cnpj}
  end

  test "rejects the reserved all-zero CNPJ" do
    assert Cnpj.normalize("00.000.000/0000-00") == {:error, :invalid_cnpj}
  end
end
