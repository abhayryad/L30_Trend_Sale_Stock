-- Step 4 (report view): V_L30_SALE_STK_MACRO_MVGR
-- PROCESS_DATA_SALE_STK_L30_DAYS (article x store) summed up to
--   SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MACRO_MVGR  +  the 155 day/metric columns.
-- SEG / DIV / SUB_DIV / MAJ_CAT come from the table itself (step 2, APP / GM / MKT only);
-- MACRO_MVGR from GOLD.DIM_PRODUCT_V2 (blank -> 'NA'; ~20% of articles on 2026-10-13).
-- No store-master filter: all stores in the table are included.
--
-- Why a procedure re-creates the view every day: the table gets new column names every day
-- ("2026-09-12_STK_Q" disappears, "2026-10-13_STK_Q" appears) and a view's column list is fixed
-- when it is created. Task TREND_L30_VIEWS re-creates it right after step 2 (TREND_L30_PIVOT).
-- If step 2 fails, this does not run, and yesterday's view still matches yesterday's table.
--
-- COPY GRANTS keeps SELECT grants given to reader roles when the view is re-created.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the tables, procedures and tasks


------------------------------------------------------------------------------
-- 1) Procedure that (re)creates the view on today's columns
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_CREATE_V_L30_SALE_STK_MACRO_MVGR()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    cols     VARCHAR;
    sql_text VARCHAR;
BEGIN
    -- SUM(A."2026-09-12_STK_Q") AS "2026-09-12_STK_Q", ... for every day/metric column
    SELECT LISTAGG('SUM(A."' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE', 'SEG', 'DIV', 'SUB_DIV', 'MAJ_CAT');

    sql_text :=
        'CREATE OR REPLACE VIEW V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR COPY GRANTS AS
         WITH PRODUCT AS (
             SELECT TRY_TO_NUMBER(ARTICLE_NUMBER)                    AS MATNR,
                    COALESCE(NULLIF(TRIM(MACRO_MVGR), ''''), ''NA'')  AS MACRO_MVGR
             FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
             QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1
         )
         SELECT A.SEG, A.DIV, A.SUB_DIV, A.STORE_CODE, A.MAJ_CAT,
                COALESCE(P.MACRO_MVGR, ''NA'') AS MACRO_MVGR, ' || cols || '
         FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS A
         LEFT JOIN PRODUCT P ON P.MATNR = A.MATNR
         GROUP BY A.SEG, A.DIV, A.SUB_DIV, A.STORE_CODE, A.MAJ_CAT, COALESCE(P.MACRO_MVGR, ''NA'')';

    EXECUTE IMMEDIATE :sql_text;

    RETURN 'V_L30_SALE_STK_MACRO_MVGR re-created';
END;
$$;

-- Create it now (needs steps 02 + 06 deployed and run first, so the table has SEG / DIV / SUB_DIV):
CALL V2RETAIL.SILVER.USP_CREATE_V_L30_SALE_STK_MACRO_MVGR();

-- Who may read it (once; COPY GRANTS keeps it on every rebuild). Replace with the real role.
-- GRANT SELECT ON VIEW V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR TO ROLE REPORT_READER_ROLE;


------------------------------------------------------------------------------
-- 2) Daily task: after step 2 (TREND_L30_PIVOT), next to TREND_L30_MAJ_CAT.
--    A task graph can only be changed while its root task is suspended.
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_VIEWS
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 4: re-create V_L30_SALE_STK_MACRO_MVGR on today''s columns'
    AFTER V2RETAIL.SILVER.TREND_L30_PIVOT
AS
    CALL V2RETAIL.SILVER.USP_CREATE_V_L30_SALE_STK_MACRO_MVGR();

ALTER TASK V2RETAIL.SILVER.TREND_L30_VIEWS RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD  RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;


------------------------------------------------------------------------------
-- 3) Checks
------------------------------------------------------------------------------
-- a) One row per grouping (expect rows = keys):
-- SELECT COUNT(*) AS rows,
--        COUNT(DISTINCT SEG||'|'||DIV||'|'||SUB_DIV||'|'||STORE_CODE||'|'||MAJ_CAT||'|'||MACRO_MVGR) AS keys
-- FROM V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR;

-- b) Totals equal the article table (replace the date with yesterday; expect identical numbers):
-- SELECT (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR)    AS view_total,
--        (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) AS table_total;

-- c) View re-created today:
-- SELECT CONVERT_TIMEZONE('Asia/Kolkata', LAST_ALTERED) AS LAST_ALTERED_IST
-- FROM V2RETAIL.INFORMATION_SCHEMA.VIEWS
-- WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'V_L30_SALE_STK_MACRO_MVGR';
