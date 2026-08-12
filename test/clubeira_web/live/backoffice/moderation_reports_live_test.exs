defmodule ClubeiraWeb.Backoffice.ModerationReportsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  @password "uma-senha-forte-para-as-denuncias-web"

  test "lists only open reports from the selected polo for a moderator", %{conn: conn} do
    fixture = open_report!()
    other_polo = open_report!()
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reports?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#moderation-reports-page")
    assert has_element?(view, "#moderation-reports #report-#{fixture.report["id"]}")
    refute has_element?(view, "#moderation-reports #report-#{other_polo.report["id"]}")
    assert has_element?(view, "#backoffice-nav-moderation[aria-current='page']")
  end

  test "hides a reported review and removes the report from the open queue", %{conn: conn} do
    fixture = open_report!()
    report_id = fixture.report["id"]
    review_id = fixture.submission.review.id
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reports?polo=#{fixture.polo_slug}")

    view
    |> form("#report-resolution-form-#{report_id}",
      resolution: %{
        action: "hide",
        reason: "A denúncia foi confirmada pela equipe responsável."
      }
    )
    |> render_submit()

    refute has_element?(view, "#report-#{report_id}")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{reports: [%{id: ^report_id, review: %{status: "hidden"}}]}} =
             Reviews.list_reports(fixture.moderator_scope, %{"status" => "accepted"})

    assert {:ok, %{reviews: [%{id: ^review_id, status: "hidden"}]}} =
             Reviews.list_for_moderation(fixture.moderator_scope, %{"status" => "hidden"})
  end

  test "rejects a resolution event for a report outside the rendered page", %{conn: conn} do
    fixture = open_report!()
    assert {:ok, %{reports: [report]}} = Reviews.list_reports(fixture.moderator_scope, %{})
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(
        "/admin/moderation/reports?polo=#{fixture.polo_slug}&after=#{cursor(report.reported_at, report.id)}"
      )

    refute has_element?(view, "#report-#{report.id}")

    render_hook(view, "resolve_report", %{
      "report_id" => report.id,
      "resolution" => %{
        "action" => "dismiss",
        "reason" => "Evento forjado fora da página renderizada.",
        "idempotency_key" => "forged-report-resolution"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{reports: [%{id: report_id, status: "open"}]}} =
             Reviews.list_reports(fixture.moderator_scope, %{})

    assert report_id == report.id
  end

  test "keeps an open report unchanged when the resolution form is invalid", %{conn: conn} do
    fixture = open_report!()
    report_id = fixture.report["id"]
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reports?polo=#{fixture.polo_slug}")

    view
    |> form("#report-resolution-form-#{report_id}",
      resolution: %{action: "", reason: ""}
    )
    |> render_submit()

    assert has_element?(view, "#report-resolution-form-#{report_id}")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{reports: [%{id: ^report_id, status: "open"}]}} =
             Reviews.list_reports(fixture.moderator_scope, %{})
  end

  test "refetches a report that another moderator already resolved", %{conn: conn} do
    fixture = open_report!()
    report_id = fixture.report["id"]
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reports?polo=#{fixture.polo_slug}")

    assert {:ok, _resolution} =
             Reviews.resolve_report(fixture.moderator_scope, %{
               review_report_id: report_id,
               action: "dismiss",
               reason: "Decisão concorrente válida.",
               idempotency_key: "concurrent-report-resolution-#{Ecto.UUID.generate()}"
             })

    view
    |> form("#report-resolution-form-#{report_id}",
      resolution: %{action: "hide", reason: "Decisão web já obsoleta."}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#report-#{report_id}")
  end

  test "a revoked browser session cannot resolve a report", %{conn: conn} do
    fixture = open_report!()
    report_id = fixture.report["id"]
    session = authenticate!(fixture.moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reports?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#report-resolution-form-#{report_id}",
      resolution: %{
        action: "dismiss",
        reason: "A sessão revogada não pode resolver uma denúncia."
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{reports: [%{id: ^report_id, status: "open"}]}} =
             Reviews.list_reports(fixture.moderator_scope, %{})
  end

  defp open_report! do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _moderation} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-report-live-#{Ecto.UUID.generate()}"
             })

    reporter = Factory.insert(:user)

    reporter_scope =
      Scope.new!(fixture.ids.polo,
        actor_user_id: reporter.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, report} =
             Reviews.report(reporter_scope, %{
               place_id: fixture.ids.place,
               review_id: fixture.submission.review.id,
               reason_code: "offensive_content",
               details: "Conteúdo ofensivo identificado após a publicação.",
               idempotency_key: "report-before-resolution-live-#{Ecto.UUID.generate()}"
             })

    fixture
    |> Map.put(:moderator_scope, moderator_scope)
    |> Map.put(:report, report)
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp cursor(recorded_at, id) do
    <<DateTime.to_unix(recorded_at, :microsecond)::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
