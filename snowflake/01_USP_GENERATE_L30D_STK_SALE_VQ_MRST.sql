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
--
-- Late sales (added 2026-10-17): on 2026-10-17 VBRP had no FP sales for 10-16 at 07:00 IST (they
-- arrived between 08:00 and 09:00), so the 07:00 run loaded stock without sales and every
-- "today" PSF value was 0. Now the task runs hourly 07:00-12:00 IST and this procedure:
--   - skips (returns, loads nothing) when PROCESS_DATA_SALE_STK_L30_DAYS already has yesterday's
--     sales, i.e. an earlier run today finished; step 2 skips too, so the big pivot runs once a day;
--   - fails before touching anything when VBRP has no FP sales for yesterday yet. A failed task
--     stops the tasks after it, so yesterday's tables stay as they are; the next hourly run retries.

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
    -- Yesterday's sales column in the main table, e.g. "2026-10-16_SALE_V"
    dt2_col  VARCHAR DEFAULT TO_CHAR(DATEADD(DAY, -1, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYY-MM-DD') || '_SALE_V';
    n_col    INTEGER DEFAULT 0;
    done_val NUMBER(38,4) DEFAULT 0;
    n_fp     INTEGER DEFAULT 0;
    rs       RESULTSET;
    no_sales EXCEPTION (-20301, 'VBRP has no FP sales for yesterday yet: nothing reloaded, yesterday''s tables stay. The next hourly run tries again.');
BEGIN
    -- Already done today? (the main table already has yesterday's sales)
    SELECT COUNT(*) INTO :n_col
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME  = :dt2_col;
    IF (n_col > 0) THEN
        rs := (EXECUTE IMMEDIATE 'SELECT COALESCE(SUM("' || dt2_col || '"), 0) AS V FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS');
        LET c1 CURSOR FOR rs;
        OPEN c1;
        FETCH c1 INTO done_val;
        CLOSE c1;
    END IF;
    IF (done_val > 0) THEN
        RETURN 'Skipped: PROCESS_DATA_SALE_STK_L30_DAYS already has ' || dt2_col;
    END IF;

    -- Yesterday's sales not in VBRP yet: stop before TREND_KPI_DATA is emptied
    SELECT COUNT(*) INTO :n_fp
    FROM V2RETAIL.BRONZE.VBRP
    WHERE FKDAT_ANA = :dt2_txt AND FKART_ANA = 'FP';
    IF (n_fp = 0) THEN
        RAISE no_sales;
    END IF;

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
