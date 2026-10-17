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
-- Skips (rebuilds nothing) when the table already has yesterday's sales, i.e. an earlier hourly
-- run today finished (added 2026-10-17, see step 1). So the pivot runs once a day.
--
-- SEG, DIV, SUB_DIV, MAJ_CAT (added 2026-10-13): taken from GOLD.DIM_PRODUCT_V2 for every MATNR,
-- so step 2b can roll up to SEG x DIV x SUB_DIV x MAJ_CAT x STORE_CODE. Blank values become 'NA'.
-- DIM_PRODUCT_V2 has one row per article (checked 2026-10-13); the QUALIFY guards against
-- duplicates appearing later.
--
-- Only SEG APP, GM, MKT are kept (user decision 2026-10-13). INNER JOIN, so articles missing
-- from the product master are dropped too (none on 2026-10-13). Dropped on 2026-10-13: FAB,
-- ACC, NT, SERVICE1 and blank SEG = ~35k articles, no sales (3 units), ~Rs 50 Cr stock value
-- on the last day (~4%). So stock totals are lower than SQL Server's, which keeps all SEGs.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    dt1  DATE DEFAULT DATEADD(DAY, -31, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE);
    cols     VARCHAR;
    sql_text VARCHAR;
    dt2_col  VARCHAR DEFAULT TO_CHAR(DATEADD(DAY, -1, CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE), 'YYYY-MM-DD') || '_SALE_V';
    n_col    INTEGER DEFAULT 0;
    done_val NUMBER(38,4) DEFAULT 0;
    rs       RESULTSET;
BEGIN
    -- Already done today? (same check as step 1)
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
             SELECT TRY_TO_NUMBER(ARTICLE_NUMBER)               AS MATNR,
                    UPPER(TRIM(SEG))                            AS SEG,
                    COALESCE(NULLIF(TRIM(DIV), ''''), ''NA'')     AS DIV,
                    COALESCE(NULLIF(TRIM(SUB_DIV), ''''), ''NA'') AS SUB_DIV,
                    COALESCE(NULLIF(TRIM(MAJ_CAT), ''''), ''NA'') AS MAJ_CAT
             FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
             QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1
         )
         SELECT T.MATNR, T.STORE_CODE, P.SEG, P.DIV, P.SUB_DIV, P.MAJ_CAT, ' || cols || '
         FROM V2RETAIL.SILVER.TREND_KPI_DATA T
         INNER JOIN PRODUCT P ON P.MATNR = T.MATNR AND P.SEG IN (''APP'', ''GM'', ''MKT'')
         GROUP BY T.MATNR, T.STORE_CODE, P.SEG, P.DIV, P.SUB_DIV, P.MAJ_CAT';

    EXECUTE IMMEDIATE :sql_text;

    RETURN 'PROCESS_DATA_SALE_STK_L30_DAYS rebuilt';
END;
$$;
