-- L30D stock + sale rolled up from MATNR x STORE_CODE to MAJ_CAT x STORE_CODE.
--
-- Reads TREND_KPI_DATA (long format) rather than PROCESS_DATA_SALE_STK_L30_DAYS, because
-- the wide table's column names change every day and can't be listed in a fixed query.
-- MAJ_CAT comes from GOLD.DIM_PRODUCT_V2 (same join as 05_). LEFT JOIN so articles
-- missing from the product master are kept under MAJ_CAT = 'NA' and totals still match.

------------------------------------------------------------------------------
-- A) Long format: one row per MAJ_CAT, STORE_CODE, date, metric
------------------------------------------------------------------------------
WITH PRODUCT AS (
    SELECT TRY_TO_NUMBER(ARTICLE_NUMBER) AS MATNR, MAJ_CAT
    FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1
)
SELECT COALESCE(P.MAJ_CAT, 'NA') AS MAJ_CAT,
       T.STORE_CODE,
       T.DATES,
       T.PARTICULARS_NAME,
       SUM(T.PARTICULARS_VALUE) AS PARTICULARS_VALUE
FROM V2RETAIL.SILVER.TREND_KPI_DATA T
LEFT JOIN PRODUCT P ON P.MATNR = T.MATNR
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;

------------------------------------------------------------------------------
-- B) Wide format: one row per MAJ_CAT + STORE_CODE, same 155 columns as
--    PROCESS_DATA_SALE_STK_L30_DAYS ("2026-09-04_STK_Q" ... "<yesterday>_SALE_GM").
--    Run the whole block; it returns the result set.
------------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
DECLARE
    dt1      DATE DEFAULT DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE);
    cols     VARCHAR;
    sql_text VARCHAR;
    res      RESULTSET;
BEGIN
    SELECT LISTAGG(
             'SUM(IFF(T.DATES = ''' || TO_CHAR(d, 'YYYY-MM-DD') || ''' AND T.PARTICULARS_NAME = ''' || m ||
             ''', T.PARTICULARS_VALUE, NULL)) AS "' || TO_CHAR(d, 'YYYY-MM-DD') || '_' || m || '"', ', ')
           WITHIN GROUP (ORDER BY d, ord)
    INTO :cols
    FROM (SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, :dt1) AS d
          FROM TABLE(GENERATOR(ROWCOUNT => 31))) days
    CROSS JOIN (SELECT column1 AS m, column2 AS ord
                FROM VALUES ('STK_Q',1), ('STK_V',2), ('SALE_Q',3), ('SALE_V',4), ('SALE_GM',5)) metrics;

    sql_text :=
        'WITH PRODUCT AS (
             SELECT TRY_TO_NUMBER(ARTICLE_NUMBER) AS MATNR, MAJ_CAT
             FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
             QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1
         )
         SELECT COALESCE(P.MAJ_CAT, ''NA'') AS MAJ_CAT, T.STORE_CODE, ' || cols || '
         FROM V2RETAIL.SILVER.TREND_KPI_DATA T
         LEFT JOIN PRODUCT P ON P.MATNR = T.MATNR
         GROUP BY 1, 2
         ORDER BY 1, 2';

    res := (EXECUTE IMMEDIATE :sql_text);
    RETURN TABLE(res);
END;
$$;
