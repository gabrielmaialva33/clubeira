defmodule ClubeiraWeb.Platform.PrivacyAccessLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Factory

  @password "uma-senha-forte-para-isolamento-lgpd"

  test "a billing-only platform operator cannot enter any privacy workspace", %{conn: conn} do
    user = Factory.insert(:user)
    grant_platform_role!(user, "platform_billing_admin")
    session = login!(user)

    paths = [
      "/platform/privacy/purposes",
      "/platform/privacy/requests",
      "/platform/privacy/requests/#{Ecto.UUID.generate(version: 7)}"
    ]

    Enum.each(paths, fn path ->
      assert {:error, {:redirect, %{to: "/platform"}}} =
               conn
               |> recycle()
               |> init_test_session(%{"backoffice_session_token" => session.token})
               |> live(path)
    end)
  end

  defp grant_platform_role!(user, role_key) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        kind: "platform",
        legal_name: "Clubeira Plataforma",
        trade_name: "Clubeira",
        status: "active"
      )

    role =
      Factory.insert(:organization_role,
        organization_id: organization.id,
        key: role_key,
        name: "Operação de billing da plataforma",
        status: "active"
      )

    membership =
      Factory.insert(:organization_membership,
        organization_id: organization.id,
        user_id: user.id,
        valid_during: Factory.tstz_range(DateTime.add(now, -60)),
        status: "active"
      )

    Factory.insert(:organization_membership_role,
      organization_id: organization.id,
      organization_membership_id: membership.id,
      organization_role_id: role.id,
      inserted_at: now
    )
  end

  defp login!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
