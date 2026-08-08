defmodule ClubeiraWeb.ReviewReportControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Factory
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-denunciar-review"

  test "an authenticated member reports a published review idempotently", %{conn: conn} do
    fixture = published_review!()
    reporter = Factory.insert(:user)
    reporter_token = authenticate!(reporter)
    path = report_path(fixture)

    request = %{
      "reason_code" => "spam",
      "details" => "A avaliação contém propaganda não relacionada."
    }

    first =
      conn
      |> put_req_header("authorization", "Bearer #{reporter_token}")
      |> put_req_header("idempotency-key", "review-report-api-001")
      |> post(path, request)
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => report_id,
               "review_id" => review_id,
               "reason_code" => "spam",
               "status" => "open",
               "reported_at" => reported_at
             }
           } = first

    assert review_id == fixture.submission.review.id
    assert {:ok, ^report_id} = Ecto.UUID.cast(report_id)
    assert {:ok, _reported_at, 0} = DateTime.from_iso8601(reported_at)
    refute inspect(first) =~ request["details"]

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{reporter_token}")
           |> put_req_header("idempotency-key", "review-report-api-001")
           |> post(path, request)
           |> json_response(201) == first
  end

  test "an author cannot report their own review", %{conn: conn} do
    fixture = published_review!()
    author = Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.ids.user)
    author_token = authenticate!(author)

    assert conn
           |> put_req_header("authorization", "Bearer #{author_token}")
           |> put_req_header("idempotency-key", "review-report-own-review")
           |> post(report_path(fixture), %{"reason_code" => "spam"})
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "a report requires one stable idempotency header", %{conn: conn} do
    fixture = published_review!()
    reporter = Factory.insert(:user)
    reporter_token = authenticate!(reporter)

    assert conn
           |> put_req_header("authorization", "Bearer #{reporter_token}")
           |> post(report_path(fixture), %{"reason_code" => "spam"})
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }
  end

  defp published_review! do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _result} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-report-#{Ecto.UUID.generate()}"
             })

    fixture
  end

  defp report_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews/" <>
      "#{fixture.submission.review.id}/reports"
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
