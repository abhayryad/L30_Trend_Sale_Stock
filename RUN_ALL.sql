-- =====================================================================
-- RUN_ALL.sql : full setup for L30D Sale & Stock in Snowflake, in order.
-- Built from the files in snowflake/ . Run top to bottom.
-- The daily tasks (section 7) are commented out: enable them only after
-- sections 1-6 look right and you have the EXECUTE TASK privilege.
-- =====================================================================

-- ---------- 0. Session ----------
USE ROLE DATA_PLATFORM_ADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE V2RETAIL;
USE SCHEMA SILVER;

-- ---------- 1. Pre-checks: confirm source columns exist ----------
DESC TABLE V2RETAIL.BRONZE.VBRP;
DESC TABLE V2RETAIL.BRONZE.ET_STOCK_DATA;
DESC TABLE V2RETAIL.GOLD.DIM_PRODUCT_V2;
DESC TABLE V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER;
DESC TABLE V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA;

-- ---------- 2. Staging table (00_) ----------
-- One-time setup: staging table filled daily by USP_GENERATE_L30D_STK_SALE_VQ_MRST.
-- Long format: one row per article x store x date x metric.
-- PARTICULARS_NAME values: STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM
--
-- Lives in V2RETAIL.SILVER (decided 2026-10-06).
-- TRANSIENT + 0-day retention: the table is emptied and refilled daily and can always be
-- rebuilt from source, so we don't pay to keep old copies (Time Travel / Fail-safe).

CREATE TRANSIENT TABLE IF NOT EXISTS V2RETAIL.SILVER.TREND_KPI_DATA (
    MATNR             NUMBER(38,0),
    STORE_CODE        VARCHAR,
    DATES             DATE,
    PARTICULARS_NAME  VARCHAR,
    PARTICULARS_VALUE NUMBER(38,4)
)
DATA_RETENTION_TIME_IN_DAYS = 0;


-- ---------- 3. Loader procedure (01_) ----------
-- Step 1 (loader): fills TREND_KPI_DATA with the last 31 days (yesterday-30 .. yesterday)
-- of stock (LGORT 0001/0006) and sales, in long format.
--
-- Sources:
--   * Stock: V2RETAIL.BRONZE.ET_STOCK_DATA (replaces ET_STOCK_DATA_LOG + ET_STOCK_DATA).
--   * Sales: V2RETAIL.BRONZE.VBRP (replaces VIEW_ET_SALES_DATA). Mapping given by user:
--       SALES_DATE = FKDAT_ANA (billing date), SALE_QTY = FKIMG, SALE_VAL = NETWR,
--       SALE_GM = NETWR - WAVWR; only billing type FKART_ANA = 'FP' (user decision 2026-10-06).
--     Replaced the earlier source V2RETAIL.SILVER.V_VBRP / PRSDT.
--   * Metric GM is named SALE_GM here (user decision 2026-10-06), so step 2 columns are
--     "<date>_SALE_GM" instead of SQL Server's "<date>_GM".
--
-- TODO before running:
--   * VBRP columns are VARCHAR; every column is converted explicitly. Run the
--     "VBRP conversion" check in 04_checks.sql: values that fail to convert
--     (e.g. SAP trailing minus '5.000-') would silently become NULL.
--   * Only FKART_ANA = 'FP' is read, so returns/cancellations with other billing types
--     are not subtracted. Compare with SQL Server to confirm that matches.
--
-- "Today" is taken in India time (Asia/Kolkata). Snowflake's CURRENT_DATE() follows the
-- session timezone, which is often US Pacific by default; SQL Server's GETDATE() used the
-- server's local (IST) clock. Step 2 uses the same expression so both steps agree.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    dt2 DATE DEFAULT DATEADD(DAY, -1, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE);
    dt1 DATE DEFAULT DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE);
    -- Same dates as 'YYYYMMDD' text, to filter VBRP.FKDAT_ANA directly (see sales part)
    dt1_txt VARCHAR DEFAULT TO_CHAR(DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYYMMDD');
    dt2_txt VARCHAR DEFAULT TO_CHAR(DATEADD(DAY, -1,  CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYYMMDD');
BEGIN
    TRUNCATE TABLE V2RETAIL.SILVER.TREND_KPI_DATA;

    -- Stock: STK_V and STK_Q
    -- In Snowflake one table holds the full daily history, so it replaces both
    -- ET_STOCK_DATA_LOG and ET_STOCK_DATA from SQL Server (no UNION needed).
    INSERT INTO V2RETAIL.SILVER.TREND_KPI_DATA (MATNR, STORE_CODE, DATES, PARTICULARS_NAME, PARTICULARS_VALUE)
    WITH cte_raw AS (
        SELECT TRY_TO_NUMBER(MATNR) AS MATNR, WERKS, STOCK_DATE::DATE AS STOCK_DATE,
               SUM(LABST_DMBTR)::NUMBER(38,4) AS STK_V, SUM(LABST)::NUMBER(38,4) AS STK_Q
        FROM V2RETAIL.BRONZE.ET_STOCK_DATA
        WHERE STOCK_DATE::DATE BETWEEN :dt1 AND :dt2 AND LGORT IN ('0001','0006')
        GROUP BY 1, 2, 3
    )
    SELECT MATNR, WERKS, STOCK_DATE, METRIC, VALUE
    FROM cte_raw UNPIVOT (VALUE FOR METRIC IN (STK_V, STK_Q));

    -- Sales: SALE_V, SALE_Q, SALE_GM
    -- VBRP columns are VARCHAR, so convert each one explicitly:
    --   * FKDAT_ANA: SAP text date 'YYYYMMDD'. Filtered as text (same order as dates, and lets
    --     Snowflake skip data it doesn't need), then converted with an explicit format;
    --     a plain ::DATE would read '20261005' as seconds since 1970.
    --   * Numbers: TRY_TO_NUMBER(x, 38, 4) keeps 4 decimals (a plain conversion drops them).
    --   * TRIM: SQL Server ignores trailing spaces in comparisons, Snowflake does not.
    INSERT INTO V2RETAIL.SILVER.TREND_KPI_DATA (MATNR, STORE_CODE, DATES, PARTICULARS_NAME, PARTICULARS_VALUE)
    WITH src AS (
        SELECT TRY_TO_NUMBER(TRIM(MATNR))                     AS MATNR,
               TRIM(WERKS)                                    AS WERKS,
               TRY_TO_DATE(FKDAT_ANA, 'YYYYMMDD')             AS SALES_DATE,
               TRY_TO_NUMBER(TRIM(FKIMG), 38, 4)              AS FKIMG,
               TRY_TO_NUMBER(TRIM(NETWR), 38, 4)              AS NETWR,
               TRY_TO_NUMBER(TRIM(WAVWR), 38, 4)              AS WAVWR
        FROM V2RETAIL.BRONZE.VBRP
        WHERE FKDAT_ANA BETWEEN :dt1_txt AND :dt2_txt
          AND FKART_ANA = 'FP'
    ),
    cte_sale AS (
        SELECT MATNR, WERKS, SALES_DATE,
               SUM(NETWR)         AS SALE_V,
               SUM(FKIMG)         AS SALE_Q,
               SUM(NETWR - WAVWR) AS SALE_GM
        FROM src
        GROUP BY 1, 2, 3
    )
    SELECT MATNR, WERKS, SALES_DATE, METRIC, VALUE
    FROM cte_sale UNPIVOT (VALUE FOR METRIC IN (SALE_V, SALE_Q, SALE_GM));

    RETURN 'TREND_KPI_DATA loaded';
END;
$$;


-- ---------- 4. Pivot procedure (02_) ----------
-- Step 2 (pivoter): rebuilds PROCESS_DATA_SALE_STK_L30_DAYS from TREND_KPI_DATA.
-- One row per MATNR + STORE_CODE, with 31 days x 5 metrics = 155 columns named
-- like "2026-09-04_STK_Q". Same names as SQL Server except GM is called SALE_GM.
--
-- Uses SUM(IFF(...)) instead of PIVOT because Snowflake's PIVOT wraps the generated
-- column names in quote marks. CREATE OR REPLACE swaps the table in one step, so
-- reports never see it missing or half-built. No indexes needed in Snowflake.
--
-- TRANSIENT + 0-day retention: rebuilt daily, so old copies are not kept (saves storage).
--
-- "Today" is taken in India time (Asia/Kolkata), same as step 1; see the note there.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    dt1  DATE DEFAULT DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE);
    cols     VARCHAR;
    sql_text VARCHAR;
BEGIN
    -- Build the 155 column expressions: one per day x metric
    SELECT LISTAGG(
             'SUM(IFF(DATES = ''' || TO_CHAR(d, 'YYYY-MM-DD') || ''' AND PARTICULARS_NAME = ''' || m ||
             ''', PARTICULARS_VALUE, NULL)) AS "' || TO_CHAR(d, 'YYYY-MM-DD') || '_' || m || '"', ', ')
           WITHIN GROUP (ORDER BY d, ord)
    INTO :cols
    FROM (SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, :dt1) AS d
          FROM TABLE(GENERATOR(ROWCOUNT => 31))) days
    CROSS JOIN (SELECT column1 AS m, column2 AS ord
                FROM VALUES ('STK_Q',1), ('STK_V',2), ('SALE_Q',3), ('SALE_V',4), ('SALE_GM',5)) metrics;

    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS
         DATA_RETENTION_TIME_IN_DAYS = 0 AS
         SELECT MATNR, STORE_CODE, ' || cols || '
         FROM V2RETAIL.SILVER.TREND_KPI_DATA
         GROUP BY MATNR, STORE_CODE';

    EXECUTE IMMEDIATE :sql_text;

    RETURN 'PROCESS_DATA_SALE_STK_L30_DAYS rebuilt';
END;
$$;


-- ---------- 5. Report procedure (05_, includes broader menu) ----------
-- Step 3 (reports): sums the 155 day/metric columns of PROCESS_DATA_SALE_STK_L30_DAYS
-- grouped by whatever descriptive columns the caller asks for (store, major category,
-- vendor, ...). One procedure serves many reports through its 3 inputs:
--
--   CAT_COLUMNS        columns to group by, comma separated      e.g. 'STORE_CODE,MAJ_CAT'
--   CAT_COLUMNS_ALIAS  what to show for them (can rename)        e.g. 'STORE_CODE AS STORE_CODE,MAJ_CAT'
--   STORE_CODES        optional store filter, comma separated    e.g. 'DB01,HB05'  ('' = all stores)
--
-- Example (same as the SQL Server example):
--   CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT', 'store_code as STORE_CODE,MAJ_CAT', '');
--
-- Broader menu (merged in 2026-10-09; replaces the separate USP_MRST_SAL_STK_L30_TREND_BROADER):
--   LEFT JOIN to V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA (alias D), matched on the first
--   10 digits of the article, so a 13-digit variant gets its 10-digit generic's attributes.
--   One row per MATNR (checked 2026-10-07), so it adds columns without changing the numbers.
--   MATNR, M_BUYING_TYPE, M_YARN, M_YARN_02 exist in both B and D: callers must prefix them
--   (B.M_YARN or D.M_YARN), otherwise Snowflake raises "ambiguous column name".
--
-- TODO before running:
--   * Joined tables: V2RETAIL.GOLD.DIM_PRODUCT_V2 (was DIM_PRODUCT in SQL Server)
--     and V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER (store master; replaced GOLD.STORE_PLANT_MASTER
--     on 2026-10-07, which was missing 71 store codes incl. 44 selling stores).
--   * Check that DIM_PRODUCT_V2 has the same column names the reports use
--     (ARTICLE_NUMBER, SEG, MAJ_CAT, MERGE_VENDOR_CODE, ...).
--   * Check how DIM_PRODUCT_V2.ARTICLE_NUMBER is stored (number, or text with leading zeros).
--     The join below uses TRY_TO_NUMBER so it works either way.
--
-- Differences from SQL Server:
--   * Square brackets in CAT_COLUMNS and CAT_COLUMNS_ALIAS (e.g. [M-VND-CD]) are turned into
--     Snowflake double quotes automatically, so existing callers can pass the same strings.
--   * Not a behaviour change, but needed for it: the VAR-ART and M-VND-CD checks ignore
--     case and outer spaces (ILIKE / UPPER / TRIM), because SQL Server's default collation
--     compares that way and Snowflake's plain = and LIKE do not.
--   * Column list read in table order (ORDINAL_POSITION) instead of sorting by the date
--     in the name; step 2 already creates them in date order.
--   * The CM_BGT_* exclusion list was dropped: those columns don't exist in this table.
--   * The extra STORE_PLANT_MASTER check on STORE_CODES was dropped: the main query
--     already inner-joins the active store master, so the result is the same.
--   * Store codes are passed as a bind value, not pasted into the SQL text.
--   * Only ACT (active) stores, same as SQL Server (user decision 2026-10-07; UPC was
--     briefly included from 2026-10-06).
--   * All objects use full names (V2RETAIL.SILVER...), so the result doesn't depend on the
--     caller's current database/schema.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND(
    CAT_COLUMNS       VARCHAR DEFAULT '',
    CAT_COLUMNS_ALIAS VARCHAR DEFAULT '',
    STORE_CODES       VARCHAR DEFAULT ''
)
RETURNS TABLE()
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    condition      VARCHAR DEFAULT '';
    columns_sum    VARCHAR;
    hierarchy_cols VARCHAR;
    select_cols    VARCHAR;
    sql_text       VARCHAR;
    res            RESULTSET;
BEGIN
    -- Extra filter for two special reports (same rules as SQL Server)
    IF (CAT_COLUMNS_ALIAS ILIKE '%VAR-ART%') THEN
        condition := 'AND LENGTH(TRY_TO_NUMBER(B.ARTICLE_NUMBER)::VARCHAR) = 13';
    ELSEIF (UPPER(TRIM(CAT_COLUMNS_ALIAS)) = 'MERGE_VENDOR_CODE AS [M-VND-CD]') THEN
        condition := 'AND B.SEG IN (''APP'',''GM'',''MKT'')';
    END IF;

    -- COALESCE(SUM("2026-09-04_STK_Q"), 0) AS "2026-09-04_STK_Q", ... for every day/metric column
    SELECT LISTAGG('COALESCE(SUM(A."' || COLUMN_NAME || '"), 0) AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :columns_sum
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE');

    -- GROUP BY list: 'STORE_CODE, MAJ_CAT' -> STORE_CODE, MAJ_CAT (spaces trimmed, [x] -> "x")
    SELECT LISTAGG(REPLACE(REPLACE(TRIM(VALUE), '[', '"'), ']', '"'), ', ') WITHIN GROUP (ORDER BY INDEX)
    INTO :hierarchy_cols
    FROM TABLE(SPLIT_TO_TABLE(:CAT_COLUMNS, ','));

    -- SQL Server [name] -> Snowflake "name"
    select_cols := REPLACE(REPLACE(CAT_COLUMNS_ALIAS, '[', '"'), ']', '"');

    sql_text :=
        'SELECT ' || select_cols || ', ' || columns_sum || '
         FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS A
         INNER JOIN V2RETAIL.GOLD.DIM_PRODUCT_V2 B
                 ON A.MATNR = TRY_TO_NUMBER(B.ARTICLE_NUMBER)
         INNER JOIN V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER C
                 ON A.STORE_CODE = C.ST_CD AND C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''
         LEFT JOIN V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA D
                 ON TRY_TO_NUMBER(LEFT(A.MATNR::VARCHAR, 10)) = TRY_TO_NUMBER(D.MATNR)
         WHERE (? = '''' OR A.STORE_CODE IN (SELECT TRIM(VALUE) FROM TABLE(SPLIT_TO_TABLE(?, '',''))))
         ' || condition || '
         GROUP BY ' || hierarchy_cols;

    res := (EXECUTE IMMEDIATE :sql_text USING (STORE_CODES, STORE_CODES));
    RETURN TABLE(res);
END;
$$;

-- The separate broader-menu procedure is no longer used (merged into 5a on 2026-10-09).
-- If it was already created in Snowflake, remove it:
DROP PROCEDURE IF EXISTS V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND_BROADER(VARCHAR, VARCHAR, VARCHAR);


-- ---------- 6. Run once by hand ----------
CALL V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST();
CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS();

-- ---------- 6b. Checks (from 04_; task-history query is at the end) ----------
-- Staging: rows per metric and date range (expect 5 metrics, 31 days).
SELECT PARTICULARS_NAME, COUNT(*) AS ROWS_, MIN(DATES) AS FIRST_DAY, MAX(DATES) AS LAST_DAY
FROM V2RETAIL.SILVER.TREND_KPI_DATA
GROUP BY 1
ORDER BY 1;

-- Today's window, in India time (should be yesterday-30 .. yesterday).
-- If FIRST_DAY/LAST_DAY above are one day earlier than this, the timezone is wrong.
SELECT DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE) AS EXPECTED_FIRST_DAY,
       DATEADD(DAY,  -1, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE) AS EXPECTED_LAST_DAY;

-- Article numbers that could not be converted to a number (MATNR ends up NULL).
-- SQL Server's TRY_CAST behaves the same, so a few rows are normal; a sudden jump is not.
SELECT PARTICULARS_NAME, COUNT(*) AS NULL_MATNR_ROWS
FROM V2RETAIL.SILVER.TREND_KPI_DATA
WHERE MATNR IS NULL
GROUP BY 1;

-- Final table: row count (one row per article + store).
SELECT COUNT(*) AS ROWS_, COUNT(DISTINCT STORE_CODE) AS STORES, COUNT(DISTINCT MATNR) AS ARTICLES
FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS;

-- VBRP conversion: columns are text. Counts values (in our window, billing type FP) that are
-- filled in but could not be converted; they become NULL and silently drop out of the sales.
-- Expect zeros. Non-zero: look at the sample query below, e.g. SAP trailing minus '5.000-'.
SELECT COUNT(*)                                                                    AS LINES_,
       COUNT_IF(TRY_TO_DATE(FKDAT_ANA, 'YYYYMMDD') IS NULL)                        AS BAD_FKDAT,
       COUNT_IF(TRIM(FKIMG) <> '' AND TRY_TO_NUMBER(TRIM(FKIMG), 38, 4) IS NULL)   AS BAD_FKIMG,
       COUNT_IF(TRIM(NETWR) <> '' AND TRY_TO_NUMBER(TRIM(NETWR), 38, 4) IS NULL)   AS BAD_NETWR,
       COUNT_IF(TRIM(WAVWR) <> '' AND TRY_TO_NUMBER(TRIM(WAVWR), 38, 4) IS NULL)   AS BAD_WAVWR,
       COUNT_IF(TRIM(MATNR) <> '' AND TRY_TO_NUMBER(TRIM(MATNR)) IS NULL)          AS BAD_MATNR
FROM V2RETAIL.BRONZE.VBRP
WHERE FKDAT_ANA BETWEEN TO_CHAR(DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYYMMDD')
                    AND TO_CHAR(DATEADD(DAY,  -1, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYYMMDD')
  AND FKART_ANA = 'FP';

-- Sample of raw values, to see the formats (brackets show hidden spaces)
SELECT '[' || FKDAT_ANA || ']' AS FKDAT_ANA, '[' || WERKS || ']' AS WERKS, MATNR, FKIMG, NETWR, WAVWR
FROM V2RETAIL.BRONZE.VBRP
WHERE FKART_ANA = 'FP'
LIMIT 20;

-- ---------- 6c. Test the report procedures ----------
CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT', 'store_code as STORE_CODE,MAJ_CAT', '');
CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT', 'store_code as STORE_CODE,MAJ_CAT', 'DB01,HB05');
CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT,D.M_YARN', 'STORE_CODE,MAJ_CAT,D.M_YARN AS M_YARN', 'DB01');

-- ---------- 7. Daily schedule (03_) - uncomment when ready ----------
-- Change the time to after the source data lands. Needs EXECUTE TASK privilege.
-- Daily automation: Task 1 runs on a schedule, Task 2 runs as soon as Task 1 succeeds.
--
-- CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_LOAD
--     WAREHOUSE = COMPUTE_WH
--     SCHEDULE  = 'USING CRON 0 7 * * * Asia/Kolkata'
-- AS
--     CALL V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST();

-- CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_PIVOT
--     WAREHOUSE = COMPUTE_WH
--     AFTER V2RETAIL.SILVER.TREND_L30_LOAD
-- AS
--     CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS();

-- Tasks are created paused. Turn them on, child first:
-- ALTER TASK V2RETAIL.SILVER.TREND_L30_PIVOT RESUME;
-- ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD  RESUME;

-- Run once now without waiting for the schedule:
-- EXECUTE TASK V2RETAIL.SILVER.TREND_L30_LOAD;

-- Pause:
-- ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

-- Next day: did the tasks run?
-- SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
-- FROM TABLE(V2RETAIL.INFORMATION_SCHEMA.TASK_HISTORY())
-- WHERE NAME IN ('TREND_L30_LOAD', 'TREND_L30_PIVOT')
-- ORDER BY SCHEDULED_TIME DESC;
