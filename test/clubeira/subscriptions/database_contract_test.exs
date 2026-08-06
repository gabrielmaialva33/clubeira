defmodule Clubeira.Subscriptions.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  test "backoffice product offering feeds have indexes matching their keyset filters" do
    assert %{rows: rows} =
             Repo.query!("""
             SELECT indexname, indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname IN (
                 'product_offerings_backoffice_feed_idx',
                 'product_offerings_backoffice_status_feed_idx'
               )
             """)

    indexes = Map.new(rows, fn [name, definition] -> {name, definition} end)

    assert indexes["product_offerings_backoffice_feed_idx"] =~
             "(polo_id, inserted_at, id)"

    assert indexes["product_offerings_backoffice_status_feed_idx"] =~
             "(polo_id, status, inserted_at, id)"
  end
end
