-- Step 2b (rollup): rebuilds PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT from PROCESS_DATA_SALE_STK_L30_DAYS.
-- One row per MAJ_CAT + STORE_CODE, same 155 day/metric columns as the article-level table
-- (e.g. "2026-09-04_STK_Q"), summed over all articles of that MAJ_CAT in that store.
--
-- Runs after step 2 (task T_L30D_MAJCAT in 03_daily_tasks.sql). The column list is read from
-- the article-level table at run time, so the dates always match it.
-- Empty days are 0, because the article-level table already has 0 instead of NULL.
-- Articles without a MAJ_CAT in the product master are under MAJ_CAT = 'NA'.
--
-- TRANSIENT + 0-day retention and CREATE OR REPLACE, same as step 2.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    cols     VARCHAR;
    sql_text VARCHAR;
BEGIN
    -- SUM("2026-09-04_STK_Q") AS "2026-09-04_STK_Q", ... for every day/metric column
    SELECT LISTAGG('SUM("' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE', 'MAJ_CAT');

    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT
         DATA_RETENTION_TIME_IN_DAYS = 0 AS
         SELECT MAJ_CAT, STORE_CODE, ' || cols || '
         FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS
         GROUP BY MAJ_CAT, STORE_CODE';

    EXECUTE IMMEDIATE :sql_text;

    RETURN 'PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT rebuilt';
END;
$$;
