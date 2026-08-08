defmodule ClubeiraWeb.BackofficeReviewReportControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Factory
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  @password "uma-senha-forte-para-moderar-denuncias"

  test "a moderator lists open reports with the reported review content", %{conn: conn} do
    fixture = open_report!()
    moderator_scope = fixture.moderator_scope
    moderator = Clubeira.Repo.get!(Clubeira.Accounts.User, moderator_scope.actor_user_id)
    moderator_token = authenticate!(moderator)

    assert %{
             "data" => [
               %{
                 "id" => report_id,
                 "review_id" => review_id,
                 "reason_code" => "offensive_content",
                 "details" => "Conteúdo ofensivo identificado após a publicação.",
                 "status" => "open",
                 "reported_at" => reported_at,
                 "review" => %{
                   "place_id" => place_id,
                   "status" => "published",
                   "revision_number" => 1,
                   "rating" => 5,
                   "title" => "Experiência verificada",
                   "body" => "O benefício foi entregue como anunciado."
                 }
               }
             ],
             "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
           } =
             conn
             |> put_req_header("authorization", "Bearer #{moderator_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports")
             |> json_response(200)

    assert report_id == fixture.report["id"]
    assert review_id == fixture.submission.review.id
    assert place_id == fixture.ids.place
    assert {:ok, _reported_at, 0} = DateTime.from_iso8601(reported_at)
  end

  test "a moderator accepts a report by hiding its review idempotently", %{conn: conn} do
    fixture = open_report!()

    moderator =
      Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.moderator_scope.actor_user_id)

    moderator_token = authenticate!(moderator)

    path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports/" <>
        "#{fixture.report["id"]}/moderation-actions"

    request = %{
      "action" => "hide",
      "reason" => "Denúncia confirmada pela moderação."
    }

    first =
      conn
      |> put_req_header("authorization", "Bearer #{moderator_token}")
      |> put_req_header("idempotency-key", "review-report-hide-api-001")
      |> post(path, request)
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => action_id,
               "review_report_id" => report_id,
               "review_id" => review_id,
               "action" => "hide",
               "report_status" => "accepted",
               "review_status" => "hidden",
               "resolved_at" => resolved_at
             }
           } = first

    assert report_id == fixture.report["id"]
    assert review_id == fixture.submission.review.id
    assert {:ok, ^action_id} = Ecto.UUID.cast(action_id)
    assert {:ok, _resolved_at, 0} = DateTime.from_iso8601(resolved_at)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "review-report-hide-api-001")
           |> post(path, request)
           |> json_response(201) == first

    assert conn
           |> recycle()
           |> get("/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews")
           |> json_response(200) == %{
             "data" => [],
             "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
           }

    assert %{
             "data" => [
               %{
                 "id" => ^report_id,
                 "reporter_user_id" => reporter_user_id,
                 "review" => %{"status" => "hidden"},
                 "resolution" => %{
                   "id" => ^action_id,
                   "action" => "hide",
                   "actor_user_id" => actor_user_id,
                   "reason" => "Denúncia confirmada pela moderação.",
                   "resolved_at" => resolution_at
                 }
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{moderator_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports?status=accepted"
             )
             |> json_response(200)

    assert reporter_user_id == fixture.reporter_scope.actor_user_id
    assert actor_user_id == fixture.moderator_scope.actor_user_id
    assert {:ok, _resolution_at, 0} = DateTime.from_iso8601(resolution_at)
  end

  test "a moderator dismisses a report without hiding the published review", %{conn: conn} do
    fixture = open_report!()

    moderator =
      Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.moderator_scope.actor_user_id)

    moderator_token = authenticate!(moderator)

    assert %{
             "data" => %{
               "review_report_id" => report_id,
               "review_id" => review_id,
               "action" => "dismiss",
               "report_status" => "rejected",
               "review_status" => "published"
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{moderator_token}")
             |> put_req_header("idempotency-key", "review-report-dismiss-api-001")
             |> post(report_action_path(fixture), %{
               "action" => "dismiss",
               "reason" => "A denúncia não procede após análise."
             })
             |> json_response(201)

    assert report_id == fixture.report["id"]
    assert review_id == fixture.submission.review.id

    assert %{"data" => [%{"id" => ^review_id}]} =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews")
             |> json_response(200)
  end

  test "a resolved report rejects a different terminal decision", %{conn: conn} do
    fixture = open_report!()

    moderator =
      Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.moderator_scope.actor_user_id)

    moderator_token = authenticate!(moderator)
    path = report_action_path(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "review-report-terminal-api-001")
           |> post(path, %{
             "action" => "hide",
             "reason" => "Primeira decisão terminal."
           })
           |> json_response(201)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "review-report-terminal-api-002")
           |> post(path, %{
             "action" => "remove",
             "reason" => "Segunda decisão não pode sobrescrever a primeira."
           })
           |> json_response(409) == %{
             "errors" => %{"detail" => "Conflict"}
           }
  end

  test "report resolution requires a moderator from the routed polo", %{conn: conn} do
    fixture = open_report!()
    reporter = Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.reporter_scope.actor_user_id)
    reporter_token = authenticate!(reporter)

    assert conn
           |> put_req_header("authorization", "Bearer #{reporter_token}")
           |> put_req_header("idempotency-key", "review-report-forbidden-api")
           |> post(report_action_path(fixture), %{
             "action" => "hide",
             "reason" => "Tentativa sem a capability necessária."
           })
           |> json_response(403) == %{
             "errors" => %{"detail" => "Forbidden"}
           }
  end

  test "report resolution validates the action and idempotency header", %{conn: conn} do
    fixture = open_report!()

    moderator =
      Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.moderator_scope.actor_user_id)

    moderator_token = authenticate!(moderator)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "review-report-invalid-action")
           |> post(report_action_path(fixture), %{
             "action" => "ban",
             "reason" => "Ação externa não suportada."
           })
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> post(report_action_path(fixture), %{
             "action" => "hide",
             "reason" => "Chave ausente."
           })
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }
  end

  test "report listing and resolution do not cross polo boundaries", %{conn: conn} do
    fixture = open_report!()
    other_fixture = open_report!()

    moderator =
      Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.moderator_scope.actor_user_id)

    moderator_token = authenticate!(moderator)

    assert %{"data" => [%{"id" => visible_report_id}]} =
             conn
             |> put_req_header("authorization", "Bearer #{moderator_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports")
             |> json_response(200)

    assert visible_report_id == fixture.report["id"]
    refute visible_report_id == other_fixture.report["id"]

    cross_polo_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports/" <>
        "#{other_fixture.report["id"]}/moderation-actions"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "review-report-cross-polo-api")
           |> post(cross_polo_path, %{
             "action" => "hide",
             "reason" => "Tentativa contra uma denúncia de outro polo."
           })
           |> json_response(404) == %{
             "errors" => %{"detail" => "Not Found"}
           }
  end

  defp open_report! do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _moderation} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-report-list-#{Ecto.UUID.generate()}"
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
               idempotency_key: "review-report-for-moderation-list"
             })

    fixture
    |> Map.put(:report, report)
    |> Map.put(:reporter_scope, reporter_scope)
    |> Map.put(:moderator_scope, moderator_scope)
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp report_action_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/review-reports/" <>
      "#{fixture.report["id"]}/moderation-actions"
  end
end
