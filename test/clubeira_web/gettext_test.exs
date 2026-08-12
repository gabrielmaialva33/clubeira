defmodule ClubeiraWeb.GettextTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.CoreComponents
  alias ClubeiraWeb.Gettext, as: GettextBackend

  test "uses the native Brazilian Portuguese plural rule for validation errors" do
    Gettext.put_locale(GettextBackend, "pt_BR")

    assert CoreComponents.translate_error({"should have %{count} item(s)", count: 1}) ==
             "deve ter 1 item"

    assert CoreComponents.translate_error({"should have %{count} item(s)", count: 2}) ==
             "deve ter 2 itens"
  end
end
