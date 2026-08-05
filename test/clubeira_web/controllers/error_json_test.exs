defmodule ClubeiraWeb.ErrorJSONTest do
  use ClubeiraWeb.ConnCase, async: true

  test "renders 404" do
    assert ClubeiraWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ClubeiraWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "includes a stable machine-readable code when the boundary provides one" do
    assert ClubeiraWeb.ErrorJSON.render("409.json", %{code: "idempotency_conflict"}) == %{
             errors: %{code: "idempotency_conflict", detail: "Conflict"}
           }
  end
end
