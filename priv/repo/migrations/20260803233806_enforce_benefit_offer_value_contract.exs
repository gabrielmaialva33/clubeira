defmodule Clubeira.Repo.Migrations.EnforceBenefitOfferValueContract do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE benefit_offers NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE benefit_offer_versions NO FORCE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM benefit_offer_versions AS version
        JOIN benefit_offers AS offer
          ON offer.id = version.benefit_offer_id
         AND offer.polo_id = version.polo_id
        WHERE
          CASE offer.benefit_kind
            WHEN 'discount_percentage' THEN
              version.amount_value IS NOT NULL
              OR version.currency IS NOT NULL
              OR (
                version.percentage_value IS NOT NULL
                AND version.percentage_value > 100
              )
              OR (
                version.status = 'published'
                AND version.percentage_value IS NULL
              )
            WHEN 'discount_amount' THEN
              version.percentage_value IS NOT NULL
              OR (
                version.amount_value IS NOT NULL
                AND version.amount_value <= 0
              )
              OR (
                version.status = 'published'
                AND (
                  version.amount_value IS NULL
                  OR version.currency IS NULL
                )
              )
            ELSE
              version.percentage_value IS NOT NULL
              OR version.amount_value IS NOT NULL
              OR version.currency IS NOT NULL
          END
      ) THEN
        RAISE EXCEPTION
          USING
            MESSAGE = 'existing benefit offer versions violate their benefit kind value contract',
            HINT = 'repair incompatible values before retrying the migration';
      END IF;
    END
    $$
    """)

    execute("ALTER TABLE benefit_offer_versions FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE benefit_offers FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE FUNCTION enforce_benefit_offer_version_value_contract()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      offer_kind text;
    BEGIN
      SELECT benefit_kind
      INTO offer_kind
      FROM benefit_offers
      WHERE id = NEW.benefit_offer_id
        AND polo_id = NEW.polo_id;

      IF offer_kind = 'discount_percentage' THEN
        IF NEW.amount_value IS NOT NULL
           OR NEW.currency IS NOT NULL
           OR (
             NEW.percentage_value IS NOT NULL
             AND NEW.percentage_value > 100
           )
           OR (
             NEW.status = 'published'
             AND NEW.percentage_value IS NULL
           ) THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'check_violation',
              CONSTRAINT = 'benefit_offer_versions_kind_value_check',
              MESSAGE = 'discount_percentage requires only percentage_value between 0 and 100 when published';
        END IF;
      ELSIF offer_kind = 'discount_amount' THEN
        IF NEW.percentage_value IS NOT NULL
           OR (
             NEW.amount_value IS NOT NULL
             AND NEW.amount_value <= 0
           )
           OR (
             NEW.status = 'published'
             AND (
               NEW.amount_value IS NULL
               OR NEW.currency IS NULL
             )
           ) THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'check_violation',
              CONSTRAINT = 'benefit_offer_versions_kind_value_check',
              MESSAGE = 'discount_amount requires only a positive amount_value and currency when published';
        END IF;
      ELSIF offer_kind IN ('complimentary_item', 'bundle', 'custom') THEN
        IF NEW.percentage_value IS NOT NULL
           OR NEW.amount_value IS NOT NULL
           OR NEW.currency IS NOT NULL THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'check_violation',
              CONSTRAINT = 'benefit_offer_versions_kind_value_check',
              MESSAGE = offer_kind || ' does not accept percentage or amount values';
        END IF;
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER benefit_offer_versions_kind_value_trigger
    BEFORE INSERT OR UPDATE OF
      polo_id,
      benefit_offer_id,
      percentage_value,
      amount_value,
      currency,
      status
    ON benefit_offer_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_benefit_offer_version_value_contract()
    """)

    execute("""
    CREATE FUNCTION prevent_benefit_offer_kind_change_with_versions()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.benefit_kind IS DISTINCT FROM OLD.benefit_kind
         AND EXISTS (
           SELECT 1
           FROM benefit_offer_versions
           WHERE benefit_offer_id = OLD.id
             AND polo_id = OLD.polo_id
         ) THEN
        RAISE EXCEPTION
          USING
            ERRCODE = 'check_violation',
            CONSTRAINT = 'benefit_offers_kind_immutable_check',
            MESSAGE = 'benefit_kind cannot change after an offer has versions';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER benefit_offers_kind_immutable_trigger
    BEFORE UPDATE OF benefit_kind
    ON benefit_offers
    FOR EACH ROW
    EXECUTE FUNCTION prevent_benefit_offer_kind_change_with_versions()
    """)
  end

  def down do
    execute("DROP TRIGGER benefit_offers_kind_immutable_trigger ON benefit_offers")
    execute("DROP FUNCTION prevent_benefit_offer_kind_change_with_versions()")

    execute("DROP TRIGGER benefit_offer_versions_kind_value_trigger ON benefit_offer_versions")
    execute("DROP FUNCTION enforce_benefit_offer_version_value_contract()")
  end
end
