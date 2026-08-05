defmodule Clubeira.Security.IdentifierVaultTest do
  use ExUnit.Case, async: true

  alias Clubeira.Security.IdentifierVault

  test "ciphertext is randomized while lookup identity remains stable and domain-separated" do
    first = IdentifierVault.seal("cnpj", "12ABC34501DE35")
    second = IdentifierVault.seal("cnpj", "12ABC34501DE35")
    other_kind = IdentifierVault.seal("tax_id", "12ABC34501DE35")

    assert first.key_version == 1
    assert second.key_version == 1
    assert first.ciphertext != second.ciphertext
    assert first.lookup_token == second.lookup_token
    assert first.lookup_token != other_kind.lookup_token
    assert :binary.match(first.ciphertext, "12ABC34501DE35") == :nomatch
  end
end
