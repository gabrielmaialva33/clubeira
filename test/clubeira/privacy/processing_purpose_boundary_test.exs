defmodule Clubeira.Privacy.ProcessingPurposeBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Privacy
  alias Clubeira.Privacy.ProcessingPurpose

  test "builds a create or update form through the public context" do
    version_id = Ecto.UUID.generate(version: 7)

    changeset =
      Privacy.change_processing_purpose(%{
        "code" => "product_research",
        "name" => "Pesquisa de produto",
        "legal_basis" => "consent",
        "legal_document_version_id" => version_id,
        "status" => "active"
      })

    assert changeset.valid?
    assert changeset.action == nil
    assert Ecto.Changeset.get_field(changeset, :code) == "product_research"
    assert Ecto.Changeset.get_field(changeset, :name) == "Pesquisa de produto"
    assert Ecto.Changeset.get_field(changeset, :legal_basis) == "consent"
    assert Ecto.Changeset.get_field(changeset, :legal_document_version_id) == version_id
    assert Ecto.Changeset.get_field(changeset, :status) == "active"
  end

  test "the form boundary rejects non-map and struct inputs without raising" do
    Enum.each([:invalid, %ProcessingPurpose{}], fn attributes ->
      changeset = Privacy.change_processing_purpose(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end)
  end
end
