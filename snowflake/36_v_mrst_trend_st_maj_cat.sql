-- V_MRST_TREND_ST_MAJ_CAT (added 2026-10-22): store x MAJ_CAT read straight from the raw
-- STORE_ARTICLE_GRID_TREND - SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE + the daily
-- <date>_STK_Q / _STK_V / _SALE_Q / _SALE_V / _SALE_GM columns summed over the articles
-- (no density, PSF, STR or area columns). Needs 32_trend_grid_tables.sql.
--
-- The table's date columns move forward every day, so a view with fixed column names breaks the next
-- day. USP_BUILD_V_MRST_TREND_ST_MAJ_CAT reads the table's current columns and recreates the view;
-- new task TREND_L30_SALE_STK_VIEW runs it after TREND_L30_GRID.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the other tables, procedures and tasks

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_V_MRST_TREND_ST_MAJ_CAT()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    sum_cols VARCHAR;
    n_cols   INTEGER;
    sql_text VARCHAR;
BEGIN
    SELECT LISTAGG('SUM("' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
           COUNT(*)
    INTO :sum_cols, :n_cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
      AND REGEXP_LIKE(COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_(STK_Q|STK_V|SALE_Q|SALE_V|SALE_GM)');

    sql_text :=
        'CREATE OR REPLACE VIEW V2RETAIL.SILVER.V_MRST_TREND_ST_MAJ_CAT COPY GRANTS AS
         SELECT SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE, ' || sum_cols || '
         FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
         GROUP BY SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE';
    EXECUTE IMMEDIATE :sql_text;

    RETURN 'V_MRST_TREND_ST_MAJ_CAT: 5 key + ' || n_cols || ' day columns';
END;
$$;

-- Build once now:
CALL V2RETAIL.SILVER.USP_BUILD_V_MRST_TREND_ST_MAJ_CAT();

SELECT TOP 100 * FROM V2RETAIL.SILVER.V_MRST_TREND_ST_MAJ_CAT;

-- First name of this view and its procedure (2026-10-22), replaced by the names above:
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_ST_MAJ_CAT_SALE_STK;
DROP PROCEDURE IF EXISTS V2RETAIL.SILVER.USP_BUILD_V_MRST_ST_MAJ_CAT_SALE_STK();

------------------------------------------------------------------------------
-- Daily: new task after TREND_L30_GRID (also in 03_daily_tasks.sql).
-- A task graph can only change while its root is suspended.
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_SALE_STK_VIEW
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 3b: recreate V_MRST_TREND_ST_MAJ_CAT on the new date columns (36_)'
    AFTER V2RETAIL.SILVER.TREND_L30_GRID
AS
    CALL V2RETAIL.SILVER.USP_BUILD_V_MRST_TREND_ST_MAJ_CAT();

ALTER TASK V2RETAIL.SILVER.TREND_L30_SALE_STK_VIEW RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;   -- TREND_L30_SALE_STK_VIEW "started"
