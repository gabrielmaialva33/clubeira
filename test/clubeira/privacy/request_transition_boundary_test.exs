defmodule Clubeira.Privacy.RequestTransitionBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope

  test "exposes the allowed lifecycle actions for each request status" do
    assert Privacy.available_actions("received") ==
             ~w(start_identity_verification start_processing reject cancel)

    assert Privacy.available_actions("identity_verification") ==
             ~w(start_processing reject cancel)

    assert Privacy.available_actions("in_progress") ==
             ~w(complete partially_complete reject cancel)

    Enum.each(~w(completed partially_completed rejected cancelled unknown), fn status ->
      assert Privacy.available_actions(status) == []
    end)

    assert Privacy.available_actions(%URI{}) == []
  end

  test "builds request-transition forms and rejects non-map payloads" do
    assert %Ecto.Changeset{valid?: true, changes: %{}} =
             Privacy.change_request_transition()

    changeset =
      Privacy.change_request_transition(%{
        "action" => "reject",
        "expected_status" => "received",
        "rejection_reason" => "Identidade não confirmada"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :action) == "reject"
    assert Ecto.Changeset.get_field(changeset, :expected_status) == "received"

    Enum.each([:invalid, %URI{}], fn attributes ->
      invalid = Privacy.change_request_transition(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)

    scope =
      ActorScope.new!(Ecto.UUID.generate(version: 7), Ecto.UUID.generate(version: 7))

    assert {:error, %Ecto.Changeset{} = command_error} =
             Privacy.transition_request(scope, Ecto.UUID.generate(version: 7), %URI{})

    assert {:base, {"must be a map", []}} in command_error.errors
  end
end
