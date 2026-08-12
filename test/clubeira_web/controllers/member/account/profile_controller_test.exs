defmodule ClubeiraWeb.Member.ProfileControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts

  @password "uma-senha-de-perfil-muito-forte"

  setup do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    %{token: session.token, user: user}
  end

  test "PUT and GET expose the authenticated civil profile without returning PII", %{
    conn: conn,
    token: token
  } do
    assert conn
           |> bearer(token)
           |> get(~p"/api/v1/me/profile")
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    update_conn =
      conn
      |> recycle()
      |> bearer(token)
      |> put(~p"/api/v1/me/profile", %{
        "display_name" => "  Ana Beatriz Souza ",
        "birth_date" => "1993-04-12",
        "cpf" => "529.982.247-25",
        "phone" => "+55 (11) 99999-9999"
      })

    assert %{
             "data" => %{
               "id" => person_id,
               "display_name" => "Ana Beatriz Souza",
               "birth_date" => "1993-04-12",
               "status" => "active",
               "identifiers" => [%{"kind" => "cpf", "verified_at" => nil}],
               "contact_points" => [
                 %{"kind" => "phone", "primary" => true, "verified_at" => nil}
               ]
             }
           } = json_response(update_conn, 200)

    assert {:ok, ^person_id} = Ecto.UUID.cast(person_id)
    refute update_conn.resp_body =~ "52998224725"
    refute update_conn.resp_body =~ "999999999"

    preserved_conn =
      conn
      |> recycle()
      |> bearer(token)
      |> put(~p"/api/v1/me/profile", %{
        "display_name" => "Ana Beatriz Maia",
        "birth_date" => "1993-04-12"
      })

    assert %{
             "data" => %{
               "display_name" => "Ana Beatriz Maia",
               "identifiers" => [%{"kind" => "cpf"}],
               "contact_points" => [%{"kind" => "phone"}]
             }
           } = json_response(preserved_conn, 200)

    cleared_conn =
      conn
      |> recycle()
      |> bearer(token)
      |> put(~p"/api/v1/me/profile", %{
        "display_name" => "Ana Beatriz Maia",
        "birth_date" => "1993-04-12",
        "cpf" => nil,
        "phone" => nil
      })

    assert %{
             "data" => %{
               "display_name" => "Ana Beatriz Maia",
               "identifiers" => [],
               "contact_points" => []
             }
           } = json_response(cleared_conn, 200)

    assert conn
           |> recycle()
           |> bearer(token)
           |> get(~p"/api/v1/me/profile")
           |> json_response(200) == json_response(cleared_conn, 200)
  end

  test "invalid input and cross-person identifiers fail with stable opaque HTTP errors", %{
    conn: conn,
    token: token
  } do
    assert conn
           |> bearer(token)
           |> put(~p"/api/v1/me/profile", %{
             "display_name" => "A",
             "cpf" => "11111111111"
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> recycle()
           |> bearer(token)
           |> put(~p"/api/v1/me/profile", %{
             "display_name" => "Primeira Pessoa",
             "cpf" => "52998224725"
           })
           |> json_response(200)

    other_user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(other_user, @password)
    assert {:ok, other_session} = Accounts.login(other_user.email, @password)

    assert conn
           |> recycle()
           |> bearer(other_session.token)
           |> put(~p"/api/v1/me/profile", %{
             "display_name" => "Segunda Pessoa",
             "cpf" => "529.982.247-25"
           })
           |> json_response(409) == %{
             "errors" => %{"code" => "profile_conflict", "detail" => "Conflict"}
           }
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
