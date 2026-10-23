-- Daily refresh of the attribute trend tables (added 2026-10-21). Needs 34_attr_trend_tables.sql.
--
-- Every set built with USP_BUILD_ATTR_TREND('<cols>') is recorded in TREND_ATTR_LIST (ACTIVE = TRUE).
-- New task TREND_L30_ATTR runs after TREND_L30_GRID and rebuilds every active set, so a new set only
-- needs its first CALL - from the next day on it is refreshed with the rest:
--
--   USE ROLE PROGRAMMER_DEV_ROLE;
--   CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND('M_FIT');     -- built now + daily from tomorrow
--
-- Stop refreshing a set (its tables stay, frozen on their last day):
--   UPDATE V2RETAIL.SILVER.TREND_ATTR_LIST SET ACTIVE = FALSE WHERE ATTR_SET = 'M_FIT';
--
-- Skip rule (the chain runs hourly 07:00-12:00 IST): a set is rebuilt only while its last table
-- (MRDC_ART_<SET>_TREND) ends before the parent's last day, so later hours skip it.
-- One set failing does not stop the others: its error goes to TREND_ATTR_LIST.LAST_ERROR, and the
-- task ends FAILED after trying all of them, so the failure shows in TASK_HISTORY; the next hour retries.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the other tables, procedures and tasks

ALTER TABLE V2RETAIL.SILVER.TREND_ATTR_LIST ADD COLUMN IF NOT EXISTS LAST_ERROR VARCHAR;

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_ATTR_TREND_ALL()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    parent_day  VARCHAR;
    set_day     VARCHAR;
    set_name    VARCHAR;
    set_attrs   VARCHAR;
    err         VARCHAR;
    n_built     INTEGER DEFAULT 0;
    n_skipped   INTEGER DEFAULT 0;
    n_failed    INTEGER DEFAULT 0;
    c_sets      CURSOR FOR SELECT ATTR_SET, ATTRS FROM V2RETAIL.SILVER.TREND_ATTR_LIST
                           WHERE ACTIVE ORDER BY ATTR_SET;
    set_failed  EXCEPTION (-20403, 'One or more attribute sets failed to build: see V2RETAIL.SILVER.TREND_ATTR_LIST.LAST_ERROR.');
BEGIN
    -- Last day in the parent, e.g. "2026-10-20"
    SELECT LEFT(MAX(COLUMN_NAME), 10) INTO :parent_day
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
      AND ENDSWITH(COLUMN_NAME, '_SALE_V');

    FOR r IN c_sets DO
        set_name  := r.ATTR_SET;
        set_attrs := r.ATTRS;

        -- Last day of the set's last-built table (NULL if it is missing)
        SELECT LEFT(MAX(COLUMN_NAME), 10) INTO :set_day
        FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'MRDC_ART_' || :set_name || '_TREND'
          AND ENDSWITH(COLUMN_NAME, '_SALE_V');

        IF (set_day IS NOT NULL AND set_day >= parent_day) THEN
            n_skipped := n_skipped + 1;
        ELSE
            BEGIN
                CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND(:set_attrs);
                UPDATE V2RETAIL.SILVER.TREND_ATTR_LIST SET LAST_ERROR = NULL WHERE ATTR_SET = :set_name;
                n_built := n_built + 1;
            EXCEPTION
                WHEN OTHER THEN
                    err := LEFT(SQLERRM, 1000);
                    UPDATE V2RETAIL.SILVER.TREND_ATTR_LIST SET LAST_ERROR = :err WHERE ATTR_SET = :set_name;
                    n_failed := n_failed + 1;
            END;
        END IF;
    END FOR;

    IF (n_failed > 0) THEN
        RAISE set_failed;
    END IF;
    RETURN 'Attribute sets up to ' || parent_day || ': ' || n_built || ' built, ' || n_skipped || ' already current.';
END;
$$;

------------------------------------------------------------------------------
-- Daily: new task after TREND_L30_GRID (also in 03_daily_tasks.sql).
-- A task graph can only change while its root is suspended.
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_ATTR
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 3: rebuild every active attribute set in TREND_ATTR_LIST (34_ / 35_)'
    AFTER V2RETAIL.SILVER.TREND_L30_GRID
AS
    CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND_ALL();

ALTER TASK V2RETAIL.SILVER.TREND_L30_ATTR RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;   -- TREND_L30_ATTR "started"

-- Try it now (COLOR and M_FIT are already on 2026-10-20, so both should skip):
CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND_ALL();

-- Sets and their state:
-- SELECT * FROM V2RETAIL.SILVER.TREND_ATTR_LIST ORDER BY ATTR_SET;
