defmodule Clubeira.Repo.Migrations.InstallRedemptionDatabaseGuards do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE FUNCTION clubeira_reject_immutable_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END;
      $$
      """,
      "DROP FUNCTION clubeira_reject_immutable_mutation()"
    )

    execute(
      """
      CREATE FUNCTION clubeira_record_initial_entitlement_grant()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        INSERT INTO entitlement_ledger_entries (
          id,
          polo_id,
          entitlement_allocation_id,
          entry_kind,
          delta_units,
          idempotency_key,
          occurred_at,
          inserted_at
        )
        VALUES (
          uuidv7(),
          NEW.polo_id,
          NEW.id,
          'initial_grant',
          NEW.issued_units,
          'allocation:' || NEW.id::text,
          NEW.inserted_at,
          now()
        );

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION clubeira_record_initial_entitlement_grant()"
    )

    execute(
      """
      CREATE FUNCTION clubeira_consume_entitlement()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        consumed boolean;
      BEGIN
        UPDATE entitlement_allocations AS allocation
        SET available_units = allocation.available_units - NEW.units,
            updated_at = now()
        WHERE allocation.id = NEW.entitlement_allocation_id
          AND allocation.polo_id = NEW.polo_id
          AND allocation.benefit_package_item_id = NEW.benefit_package_item_id
          AND allocation.available_units >= NEW.units
          AND EXISTS (
            SELECT 1
            FROM redemption_attempts AS attempt
            WHERE attempt.id = NEW.redemption_attempt_id
              AND attempt.polo_id = NEW.polo_id
              AND attempt.decision = 'accepted'
          )
          AND (
            (
              allocation.allocation_kind = 'per_place'
              AND allocation.polo_place_id = NEW.polo_place_id
            )
            OR
            (
              allocation.allocation_kind = 'shared_scope'
              AND EXISTS (
                SELECT 1
                FROM entitlement_scope_places AS scope_place
                WHERE scope_place.polo_id = NEW.polo_id
                  AND scope_place.entitlement_scope_id = allocation.entitlement_scope_id
                  AND scope_place.polo_place_id = NEW.polo_place_id
              )
            )
          )
        RETURNING true INTO consumed;

        IF NOT coalesce(consumed, false) THEN
          RAISE EXCEPTION 'entitlement allocation is invalid or exhausted'
            USING ERRCODE = 'check_violation';
        END IF;

        INSERT INTO entitlement_ledger_entries (
          id,
          polo_id,
          entitlement_allocation_id,
          redemption_id,
          entry_kind,
          delta_units,
          idempotency_key,
          occurred_at,
          inserted_at
        )
        VALUES (
          uuidv7(),
          NEW.polo_id,
          NEW.entitlement_allocation_id,
          NEW.id,
          'consumption',
          -NEW.units,
          'redemption:' || NEW.id::text,
          NEW.redeemed_at,
          now()
        );

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION clubeira_consume_entitlement()"
    )

    execute(
      """
      CREATE TRIGGER entitlement_allocations_initial_grant
      AFTER INSERT ON entitlement_allocations
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_record_initial_entitlement_grant();
      """,
      "DROP TRIGGER entitlement_allocations_initial_grant ON entitlement_allocations"
    )

    execute(
      """
      CREATE TRIGGER redemptions_consume_entitlement
      AFTER INSERT ON redemptions
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_consume_entitlement();
      """,
      "DROP TRIGGER redemptions_consume_entitlement ON redemptions"
    )

    execute(
      """
      CREATE TRIGGER redemption_attempts_append_only
      BEFORE UPDATE OR DELETE ON redemption_attempts
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER redemption_attempts_append_only ON redemption_attempts"
    )

    execute(
      """
      CREATE TRIGGER redemptions_append_only
      BEFORE UPDATE OR DELETE ON redemptions
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER redemptions_append_only ON redemptions"
    )

    execute(
      """
      CREATE TRIGGER redemption_reversals_append_only
      BEFORE UPDATE OR DELETE ON redemption_reversals
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER redemption_reversals_append_only ON redemption_reversals"
    )

    execute(
      """
      CREATE TRIGGER redemption_events_append_only
      BEFORE UPDATE OR DELETE ON redemption_events
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER redemption_events_append_only ON redemption_events"
    )

    execute(
      """
      CREATE TRIGGER entitlement_ledger_entries_append_only
      BEFORE UPDATE OR DELETE ON entitlement_ledger_entries
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER entitlement_ledger_entries_append_only ON entitlement_ledger_entries"
    )
  end
end
