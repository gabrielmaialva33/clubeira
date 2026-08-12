defmodule ClubeiraWeb.GettextTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.CoreComponents
  alias ClubeiraWeb.Gettext, as: GettextBackend
  alias ClubeiraWeb.Gettext.Plural

  test "uses the native Brazilian Portuguese plural rule for validation errors" do
    Gettext.put_locale(GettextBackend, "pt_BR")

    assert CoreComponents.translate_error({"should have %{count} item(s)", count: 1}) ==
             "deve ter 1 item"

    assert CoreComponents.translate_error({"should have %{count} item(s)", count: 2}) ==
             "deve ter 2 itens"
  end

  test "delegates the complete plural callback contract to Gettext" do
    assert Plural.nplurals("pt_BR") == 2
    assert Plural.plural("pt_BR", 1) == 0
    assert Plural.plural("pt_BR", 2) == 1
    assert Plural.plural_forms_header("pt_BR") =~ "nplurals=2"
  end
end
