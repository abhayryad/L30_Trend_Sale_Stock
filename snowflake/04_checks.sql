-- Did the tasks run? Latest first.
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(V2RETAIL.INFORMATION_SCHEMA.TASK_HISTORY())
WHERE NAME IN ('TREND_L30_LOAD', 'TREND_L30_PIVOT')
ORDER BY SCHEDULED_TIME DESC;

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
