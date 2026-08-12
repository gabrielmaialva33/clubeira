defmodule ClubeiraWeb.Member.ProfileLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-o-perfil-web"

  test "creates a protected self profile without reflecting sensitive values", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    session = authenticate!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/profile")

    view
    |> form("#member-profile-form",
      self_profile: %{
        display_name: "Ana Beatriz Souza",
        birth_date: "1993-04-12",
        cpf: "529.982.247-25",
        phone: "+55 (11) 99999-9999"
      }
    )
    |> render_submit()

    assert has_element?(view, "#member-profile-state")
    assert has_element?(view, "#profile-cpf-present")
    assert has_element?(view, "#profile-phone-present")

    html = render(view)
    refute html =~ "52998224725"
    refute html =~ "999999999"
  end

  test "updates display data without deleting write-only credentials", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    actor_scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, _profile} =
             People.put_self_profile(actor_scope, %{
               "display_name" => "Nome Original",
               "cpf" => "52998224725",
               "phone" => "11999999999"
             })

    session = authenticate!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/profile")

    view
    |> form("#member-profile-form",
      self_profile: %{display_name: "Nome Atualizado", birth_date: "", cpf: "", phone: ""}
    )
    |> render_submit()

    assert {:ok, profile} = People.get_self_profile(actor_scope)
    assert profile.display_name == "Nome Atualizado"
    assert Enum.any?(profile.identifiers, &(&1.kind == "cpf"))
    assert Enum.any?(profile.contact_points, &(&1.kind == "phone"))
  end

  test "revalidates the session before saving", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    session = authenticate!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/profile")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view
             |> form("#member-profile-form", self_profile: %{display_name: "Não persiste"})
             |> render_submit()
  end

  test "shows boundary validation and survives malformed form events", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    session = authenticate!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/profile")

    view
    |> form("#member-profile-form",
      self_profile: %{
        display_name: "x",
        birth_date: Date.utc_today() |> Date.add(1) |> Date.to_iso8601(),
        cpf: "invalid",
        phone: "invalid"
      }
    )
    |> render_change()

    assert has_element?(view, "#self_profile_display_name.border-red-500")
    assert has_element?(view, "#self_profile_birth_date.border-red-500")
    assert has_element?(view, "#self_profile_cpf.border-red-500")
    assert has_element?(view, "#self_profile_phone.border-red-500")

    render_hook(view, "validate_profile", %{})
    render_hook(view, "save_profile", %{})

    assert has_element?(view, "#member-profile")
    assert has_element?(view, "#flash-error")
  end

  test "does not link a CPF already owned by another profile", %{conn: conn} do
    existing_user = Clubeira.Factory.insert(:user)
    existing_scope = ActorScope.new!(existing_user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, _profile} =
             People.put_self_profile(existing_scope, %{
               "display_name" => "Titular existente",
               "cpf" => "52998224725"
             })

    user = Clubeira.Factory.insert(:user)
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))
    session = authenticate!(user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/profile")

    view
    |> form("#member-profile-form",
      self_profile: %{display_name: "Outro titular", cpf: "529.982.247-25"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert {:error, :profile_not_found} = People.get_self_profile(scope)
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
