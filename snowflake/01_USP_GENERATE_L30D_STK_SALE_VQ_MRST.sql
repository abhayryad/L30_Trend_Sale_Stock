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
