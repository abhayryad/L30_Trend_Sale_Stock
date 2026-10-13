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
-- Empty days are 0, not NULL (user decision 2026-10-13; SQL Server's PIVOT gave NULL).
--
-- "Today" is taken in India time (Asia/Kolkata), same as step 1; see the note there.
--
-- MAJ_CAT (added 2026-10-13): taken from GOLD.DIM_PRODUCT_V2 for every MATNR, so step 2b can
-- roll up to MAJ_CAT x STORE_CODE. LEFT JOIN: articles missing from the product master, or
-- with a blank MAJ_CAT, get 'NA' and are kept. DIM_PRODUCT_V2 has one row per article
-- (checked 2026-10-13); the QUALIFY guards against duplicates appearing later.

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
             'COALESCE(SUM(IFF(T.DATES = ''' || TO_CHAR(d, 'YYYY-MM-DD') || ''' AND T.PARTICULARS_NAME = ''' || m ||
             ''', T.PARTICULARS_VALUE, NULL)), 0) AS "' || TO_CHAR(d, 'YYYY-MM-DD') || '_' || m || '"', ', ')
           WITHIN GROUP (ORDER BY d, ord)
    INTO :cols
    FROM (SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, :dt1) AS d
          FROM TABLE(GENERATOR(ROWCOUNT => 31))) days
    CROSS JOIN (SELECT column1 AS m, column2 AS ord
                FROM VALUES ('STK_Q',1), ('STK_V',2), ('SALE_Q',3), ('SALE_V',4), ('SALE_GM',5)) metrics;

    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS
         DATA_RETENTION_TIME_IN_DAYS = 0 AS
         WITH PRODUCT AS (
             SELECT TRY_TO_NUMBER(ARTICLE_NUMBER) AS MATNR, NULLIF(TRIM(MAJ_CAT), '''') AS MAJ_CAT
             FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
             QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1
         )
         SELECT T.MATNR, T.STORE_CODE, COALESCE(P.MAJ_CAT, ''NA'') AS MAJ_CAT, ' || cols || '
         FROM V2RETAIL.SILVER.TREND_KPI_DATA T
         LEFT JOIN PRODUCT P ON P.MATNR = T.MATNR
         GROUP BY T.MATNR, T.STORE_CODE, COALESCE(P.MAJ_CAT, ''NA'')';

    EXECUTE IMMEDIATE :sql_text;

    RETURN 'PROCESS_DATA_SALE_STK_L30_DAYS rebuilt';
END;
$$;
