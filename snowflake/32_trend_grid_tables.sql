-- The raw grid table + the 4 trend grid tables with PSF and H/V (added 2026-10-17). The 4 replace the
-- 18 views of the store and MRDC PSF chains (files 20-30); those stay until the new tables are checked
-- against them, then they are retired.
--
--   Table (V2RETAIL.SILVER)   Replaces                                          Grain
--   STORE_ARTICLE_GRID_TREND  -                                                 store x article, raw "original
--                                                                               copy": data + attributes only
--   MRST_ST_MAJ_CAT_TREND     V_MAJ_CAT_TREND (+ _PSF, _PSF_SUMMARY)            store x SEG/DIV/SUB_DIV/MAJ_CAT
--   MRST_ST_ART_TREND         V_TREND_30_DAYS_GRID (+ _PSF, _PSF_SUMMARY),      store x article
--                             V_ARTICLE_MAJCAT_PSF, _ACH, V_ARTICLE_HV
--   MRDC_MAJ_CAT_TREND        V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID (+ _PSF, _SUMMARY)  MAJ_CAT, stores summed
--   MRDC_ART_TREND            V_MRDC_TREND_30_DAYS_GRID (+ _PSF, _SUMMARY),     article, stores summed
--                             V_MRDC_ARTICLE_MAJCAT_PSF, _ACH, V_MRDC_ARTICLE_HV
--
-- Columns of the 4 tables, in order:
--   keys / attributes
--   FINAL_DENSITY, APF, PPA
--   SALE_PSF_, GP_PSF_, STR_ x MTD, L7D, 30D, TD                (averages)
--   article tables only:
--     MAJCAT_SALE_PSF_*, MAJCAT_GP_PSF_*, MAJCAT_STR_*           (their store x MAJ_CAT / MAJ_CAT averages)
--     8 achievement columns: ST_MAJ_CAT_<TD|MTD|L7D|30D>_<SALE|GP>_ACHIEVEMENT (MRST),
--                            MAJ_CAT_<...>_ACHIEVEMENT (MRDC), text like '125%'
--     ARTICLE_HV
--   per day: "<day>_STK_Q", _STK_V, _SALE_Q, _SALE_V, _SALE_GM, FINAL_AREA_<day>, SALE_PSF_<day>,
--            GP_PSF_<day>, STR_<day>                             (day as YYYY_MM_DD in the KPI names)
--
-- PSF logic: the same formulas as USP_REBUILD_PSF_VIEWS (30_) and files 21-23 / 27-29:
--   PPA     MRST: "FINAL DENSITY" (store + MAJ_CAT) / MAX(APF) of the store
--           MRDC: AVG("FINAL DENSITY") of the MAJ_CAT / 22 (APF shown as 22)
--   FINAL_AREA_<day> = STK_Q * PPA;  SALE_PSF = SALE_V / FINAL_AREA;  GP_PSF = SALE_GM / FINAL_AREA;
--   STR = STK_V / (SALE_V - SALE_GM). Averages relative to the last day D, over days with a value > 0
--   only: MTD = 1st of D's month .. D, L7D = D-6 .. D, 30D = D-29 .. D, TD = D.
--   Missing values and divide-by-zero come out as 0, never NULL.
--   Article benchmark: MRST = the article's store + MAJ_CAT row of MRST_ST_MAJ_CAT_TREND,
--   MRDC = the article's MAJ_CAT row of MRDC_MAJ_CAT_TREND. Achievement = article / benchmark * 100.
--   ARTICLE_HV: band each of SALE 30D, SALE L7D, GP 30D, GP L7D achievement (rounded %):
--     <= 25 D | <= 50 VV | <= 90 V | <= 125 N | <= 170 H | <= 200 HH | > 200 G
--   all four in the same band = that band, otherwise 'NA'.
--
-- Space plan (user rule 2026-10-17): V2RETAIL.AKS_GOLD.SPACE_PLAN_<current month, IST>_<YYYYMMDD>_<HHMMSS>
-- with the latest timestamp in its name (range names like SPACE_PLAN_JUL_SEP_... never match; empty copies
-- are skipped). The name used is in the procedure's return value (TASK_HISTORY.RETURN_VALUE).
--
-- Other decisions 2026-10-17:
--   * Same rows as the old views: SEG APP / GM / MKT (main table), active stores only
--     (SLV_MIS_STORE_MASTER ST_STAT = 'ACT' AND ST_TYP = 'STORE').
--   * Clean column names: SUB_DIV, MAJ_CAT, MC_CODE, MERGE_VENDOR_CODE.
--   * Article tables carry all attributes: every DIM_PRODUCT_V2 column (P, on MATNR), COLOR / SIZE from
--     VW_PRODUCT_MASTER only (NEW_COLOR_CODE / NEW_SIZE_DESC), every ET_ART_BROADER_MENU_DATA column (D, on
--     the 10-digit generic article). Left out: DIM's COLOR, COLOR_NEW, SIZE_1, SIZE_STD; load columns
--     ROW_HASH, ATTR_SOURCE, LVORM_RAW, CREATE_DATE, MODIFY_DATE, STOCK_DATE. Names in both P and D
--     (M_YARN, M_YARN_02, M_BUYING_TYPE) from DIM. Blank text -> 'NA'. Lists read from INFORMATION_SCHEMA.
--   * The raw copy never gets calculations; all 4 tables are built from it.
--
-- Daily: task TREND_L30_GRID after TREND_L30_PIVOT (03_daily_tasks.sql), hourly 07:00-12:00, so the
-- procedure skips once the raw copy has the main table's last day and MRDC_ART_TREND (built last) has
-- its FINAL_AREA column.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the other tables, procedures and tasks

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_TREND_GRID_TABLES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    last_col     VARCHAR;
    last_day     DATE;
    n_have       INTEGER DEFAULT 0;
    sp           VARCHAR;
    p_cols       VARCHAR;
    d_cols       VARCHAR;
    raw_days     VARCHAR;
    sum_cols     VARCHAR;
    st_art_keys  VARCHAR;
    art_keys     VARCHAR;
    day_cols     VARCHAR;
    day_names    VARCHAR;
    avg_cols     VARCHAR;
    avg_names    VARCHAR;
    mc_cols      VARCHAR;
    mc_names     VARCHAR;
    ach_t        VARCHAR;
    pct_cols     VARCHAR;
    hv_expr      VARCHAR;
    band_t       VARCHAR DEFAULT 'CASE WHEN {X} <= 25 THEN ''D'' WHEN {X} <= 50 THEN ''VV'' WHEN {X} <= 90 THEN ''V'' WHEN {X} <= 125 THEN ''N'' WHEN {X} <= 170 THEN ''H'' WHEN {X} <= 200 THEN ''HH'' ELSE ''G'' END';
    mrst_base    VARCHAR;
    mrdc_base    VARCHAR;
    sql_text     VARCHAR;
    no_plan      EXCEPTION (-20401, 'No SPACE_PLAN_<current month>_<timestamp> table with rows in V2RETAIL.AKS_GOLD.');
BEGIN
    -- Last day in the main table, e.g. "2026-10-16_SALE_V"
    SELECT MAX(COLUMN_NAME) INTO :last_col
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND ENDSWITH(COLUMN_NAME, '_SALE_V');
    last_day := TO_DATE(LEFT(last_col, 10));

    -- Done today? Raw copy (built first) has the day, MRDC_ART_TREND (built last) has its PSF columns
    SELECT COUNT(DISTINCT TABLE_NAME) INTO :n_have
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND ((TABLE_NAME = 'STORE_ARTICLE_GRID_TREND' AND COLUMN_NAME = :last_col)
        OR (TABLE_NAME = 'MRDC_ART_TREND' AND COLUMN_NAME = 'FINAL_AREA_' || TO_CHAR(:last_day, 'YYYY_MM_DD')));
    IF (n_have = 2) THEN
        RETURN 'Skipped: trend grid tables already have ' || last_col;
    END IF;

    -- Space plan: current month (IST), latest timestamp in the name, not empty
    SELECT MAX(TABLE_NAME) INTO :sp
    FROM V2RETAIL.INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = 'AKS_GOLD'
      AND REGEXP_LIKE(TABLE_NAME, 'SPACE_PLAN_' || UPPER(TO_CHAR(CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE, 'MON')) || '_[0-9]{8}_[0-9]{6}')
      AND ROW_COUNT > 0;
    IF (sp IS NULL) THEN
        RAISE no_plan;
    END IF;
    sp := 'V2RETAIL.AKS_GOLD.' || sp;

    ------------------------------------------------------------------------
    -- Column lists
    ------------------------------------------------------------------------
    -- Attributes; text columns: blank / missing -> 'NA'
    SELECT LISTAGG(IFF(DATA_TYPE = 'TEXT',
                       'COALESCE(NULLIF(TRIM(P."' || COLUMN_NAME || '"), ''''), ''NA'') AS "' || COLUMN_NAME || '"',
                       'P."' || COLUMN_NAME || '"'), ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :p_cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'GOLD' AND TABLE_NAME = 'DIM_PRODUCT_V2'
      AND COLUMN_NAME NOT IN ('MATNR', 'SEG', 'DIV', 'SUB_DIV', 'MAJ_CAT', 'STORE_CODE',
                              'COLOR', 'COLOR_NEW', 'SIZE_1', 'SIZE_STD',
                              'ROW_HASH', 'ATTR_SOURCE', 'LVORM_RAW', 'CREATE_DATE', 'MODIFY_DATE');

    SELECT LISTAGG(IFF(DATA_TYPE = 'TEXT',
                       'COALESCE(NULLIF(TRIM(D."' || COLUMN_NAME || '"), ''''), ''NA'') AS "' || COLUMN_NAME || '"',
                       'D."' || COLUMN_NAME || '"'), ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :d_cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'BRONZE' AND TABLE_NAME = 'ET_ART_BROADER_MENU_DATA'
      AND COLUMN_NAME NOT IN ('MATNR', 'STOCK_DATE', 'COLOR', 'SIZE', 'STORE_CODE')
      AND COLUMN_NAME NOT IN (SELECT COLUMN_NAME FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
                              WHERE TABLE_SCHEMA = 'GOLD' AND TABLE_NAME = 'DIM_PRODUCT_V2');

    -- Raw day columns: as they are for the raw copy, summed for the MAJ_CAT / MRDC tables
    SELECT LISTAGG('A."' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
           LISTAGG('SUM("' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :raw_days, :sum_cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE', 'SEG', 'DIV', 'SUB_DIV', 'MAJ_CAT');

    -- Per day: the 5 raw values, then FINAL_AREA / SALE_PSF / GP_PSF / STR (expressions and names)
    WITH DAYS AS (
        SELECT DISTINCT TO_DATE(LEFT(COLUMN_NAME, 10)) AS D
        FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'PROCESS_DATA_SALE_STK_L30_DAYS'
          AND REGEXP_LIKE(COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_.+')
    )
    SELECT LISTAGG(REPLACE(REPLACE(
               'COALESCE("{D}_STK_Q", 0) AS "{D}_STK_Q", ' ||
               'COALESCE("{D}_STK_V", 0) AS "{D}_STK_V", ' ||
               'COALESCE("{D}_SALE_Q", 0) AS "{D}_SALE_Q", ' ||
               'COALESCE("{D}_SALE_V", 0) AS "{D}_SALE_V", ' ||
               'COALESCE("{D}_SALE_GM", 0) AS "{D}_SALE_GM", ' ||
               'COALESCE("{D}_STK_Q", 0) * PPA AS FINAL_AREA_{S}, ' ||
               'COALESCE(DIV0NULL("{D}_SALE_V", COALESCE("{D}_STK_Q", 0) * PPA), 0) AS SALE_PSF_{S}, ' ||
               'COALESCE(DIV0NULL("{D}_SALE_GM", COALESCE("{D}_STK_Q", 0) * PPA), 0) AS GP_PSF_{S}, ' ||
               'COALESCE(DIV0NULL("{D}_STK_V", COALESCE("{D}_SALE_V", 0) - COALESCE("{D}_SALE_GM", 0)), 0) AS STR_{S}',
               '{D}', TO_CHAR(D, 'YYYY-MM-DD')), '{S}', TO_CHAR(D, 'YYYY_MM_DD')), ', ')
               WITHIN GROUP (ORDER BY D),
           LISTAGG(REPLACE(REPLACE(
               '"{D}_STK_Q", "{D}_STK_V", "{D}_SALE_Q", "{D}_SALE_V", "{D}_SALE_GM", ' ||
               'FINAL_AREA_{S}, SALE_PSF_{S}, GP_PSF_{S}, STR_{S}',
               '{D}', TO_CHAR(D, 'YYYY-MM-DD')), '{S}', TO_CHAR(D, 'YYYY_MM_DD')), ', ')
               WITHIN GROUP (ORDER BY D)
    INTO :day_cols, :day_names
    FROM DAYS;

    -- Averages per KPI, in the order MTD, L7D, 30D, TD (same as the old PSF views)
    WITH DAYS AS (
        SELECT DISTINCT TO_DATE(LEFT(COLUMN_NAME, 10)) AS D
        FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'PROCESS_DATA_SALE_STK_L30_DAYS'
          AND REGEXP_LIKE(COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_.+')
    )
    SELECT LISTAGG(EXPR, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD),
           LISTAGG(K || '_' || W, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :avg_cols, :avg_names
    FROM (
        SELECT k.K, k.K_ORD, w.W, w.W_ORD,
               IFF(w.W = 'TD',
                   k.K || '_' || TO_CHAR(:last_day, 'YYYY_MM_DD') || ' AS ' || k.K || '_TD',
                   'COALESCE(DIV0NULL(' ||
                   LISTAGG('IFF(' || k.K || '_' || TO_CHAR(d.D, 'YYYY_MM_DD') || ' > 0, ' || k.K || '_' || TO_CHAR(d.D, 'YYYY_MM_DD') || ', 0)', ' + ')
                       WITHIN GROUP (ORDER BY d.D) || ', ' ||
                   LISTAGG('IFF(' || k.K || '_' || TO_CHAR(d.D, 'YYYY_MM_DD') || ' > 0, 1, 0)', ' + ')
                       WITHIN GROUP (ORDER BY d.D) ||
                   '), 0) AS ' || k.K || '_' || w.W) AS EXPR
        FROM (SELECT column1 AS K, column2 AS K_ORD FROM VALUES ('SALE_PSF', 1), ('GP_PSF', 2), ('STR', 3)) k
        CROSS JOIN (SELECT column1 AS W, column2 AS W_ORD FROM VALUES ('MTD', 1), ('L7D', 2), ('30D', 3), ('TD', 4)) w
        JOIN DAYS d
          ON (w.W = 'MTD' AND d.D >= DATE_TRUNC('MONTH', :last_day))
          OR (w.W = 'L7D' AND d.D >  DATEADD(DAY, -7, :last_day))
          OR (w.W = '30D' AND d.D >  DATEADD(DAY, -30, :last_day))
          OR (w.W = 'TD'  AND d.D =  :last_day)
        GROUP BY k.K, k.K_ORD, w.W, w.W_ORD
    );

    -- Benchmark averages next to each article (same order as the averages)
    SELECT LISTAGG('COALESCE(M.' || K || '_' || W || ', 0) AS MAJCAT_' || K || '_' || W, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD),
           LISTAGG('MAJCAT_' || K || '_' || W, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :mc_cols, :mc_names
    FROM (SELECT column1 AS K, column2 AS K_ORD FROM VALUES ('SALE_PSF', 1), ('GP_PSF', 2), ('STR', 3)) k
    CROSS JOIN (SELECT column1 AS W, column2 AS W_ORD FROM VALUES ('MTD', 1), ('L7D', 2), ('30D', 3), ('TD', 4)) w;

    -- Achievement: TD, MTD, L7D, 30D for SALE, then GP; {PFX} = ST_MAJ_CAT_ (MRST) or MAJ_CAT_ (MRDC)
    SELECT LISTAGG('TO_VARCHAR(ROUND(COALESCE(DIV0NULL(' || K || '_PSF_' || W || ', MAJCAT_' || K || '_PSF_' || W ||
                   '), 0) * 100, 0)::INT) || ''%'' AS {PFX}' || W || '_' || K || '_ACHIEVEMENT', ', ')
               WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :ach_t
    FROM (SELECT column1 AS K, column2 AS K_ORD FROM VALUES ('SALE', 1), ('GP', 2)) k
    CROSS JOIN (SELECT column1 AS W, column2 AS W_ORD FROM VALUES ('TD', 1), ('MTD', 2), ('L7D', 3), ('30D', 4)) w;

    -- H/V: the 4 rounded achievements, banded; all four the same band = that band, else 'NA'
    pct_cols := 'ROUND(COALESCE(DIV0NULL(SALE_PSF_30D, MAJCAT_SALE_PSF_30D), 0) * 100, 0) AS P_SALE_30D, ' ||
                'ROUND(COALESCE(DIV0NULL(SALE_PSF_L7D, MAJCAT_SALE_PSF_L7D), 0) * 100, 0) AS P_SALE_L7D, ' ||
                'ROUND(COALESCE(DIV0NULL(GP_PSF_30D,   MAJCAT_GP_PSF_30D),   0) * 100, 0) AS P_GP_30D, ' ||
                'ROUND(COALESCE(DIV0NULL(GP_PSF_L7D,   MAJCAT_GP_PSF_L7D),   0) * 100, 0) AS P_GP_L7D';
    hv_expr := 'IFF(' || REPLACE(band_t, '{X}', 'P_SALE_30D') || ' = ' || REPLACE(band_t, '{X}', 'P_SALE_L7D') ||
               ' AND ' || REPLACE(band_t, '{X}', 'P_SALE_30D') || ' = ' || REPLACE(band_t, '{X}', 'P_GP_30D') ||
               ' AND ' || REPLACE(band_t, '{X}', 'P_SALE_30D') || ' = ' || REPLACE(band_t, '{X}', 'P_GP_L7D') ||
               ', ' || REPLACE(band_t, '{X}', 'P_SALE_30D') || ', ''NA'')';

    -- PPA, per level. {SRC} = the rows to price.
    mrst_base := 'SPA AS (SELECT ST_CD, MAX(APF) AS APF FROM ' || sp || ' GROUP BY ST_CD),
         BASE AS (
             SELECT COALESCE(D."FINAL DENSITY", 0) AS FINAL_DENSITY,
                    COALESCE(S.APF, 0)             AS APF,
                    COALESCE(DIV0NULL(D."FINAL DENSITY", S.APF), 0) AS PPA,
                    A.*
             FROM {SRC} A
             LEFT JOIN SPA S ON A.STORE_CODE = S.ST_CD
             LEFT JOIN ' || sp || ' D ON A.STORE_CODE = D.ST_CD AND A.MAJ_CAT = D.MAJ_CAT)';
    mrdc_base := 'SPA AS (SELECT MAJ_CAT, AVG("FINAL DENSITY") AS FINAL_DENSITY FROM ' || sp || ' GROUP BY MAJ_CAT),
         BASE AS (
             SELECT COALESCE(S.FINAL_DENSITY, 0)      AS FINAL_DENSITY,
                    22                                AS APF,
                    COALESCE(S.FINAL_DENSITY, 0) / 22 AS PPA,
                    A.*
             FROM {SRC} A
             LEFT JOIN SPA S ON A.MAJ_CAT = S.MAJ_CAT)';

    ------------------------------------------------------------------------
    -- 1) STORE_ARTICLE_GRID_TREND: the raw copy, store x article. Each lookup cut to one row per key
    --    first, so a join never multiplies rows.
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         SELECT A.SEG, A.DIV, A.SUB_DIV, A.STORE_CODE, A.MATNR, A.MAJ_CAT,
                ' || p_cols || ',
                COALESCE(NULLIF(TRIM(M.NEW_COLOR_CODE), ''''), ''NA'') AS COLOR,
                COALESCE(NULLIF(TRIM(M.NEW_SIZE_DESC), ''''), ''NA'')  AS SIZE,
                ' || d_cols || ',
                ' || raw_days || '
         FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS A
         JOIN (SELECT DISTINCT ST_CD FROM V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER
               WHERE ST_STAT = ''ACT'' AND ST_TYP = ''STORE'') C
                ON A.STORE_CODE = C.ST_CD
         LEFT JOIN (SELECT * FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1) P
                ON A.MATNR = TRY_TO_NUMBER(P.ARTICLE_NUMBER)
         LEFT JOIN (SELECT TRY_TO_NUMBER(ARTICLE_NUMBER) AS MATNR, NEW_COLOR_CODE, NEW_SIZE_DESC
                    FROM V2RETAIL.SILVER.VW_PRODUCT_MASTER
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY MATNR ORDER BY NEW_COLOR_CODE) = 1) M
                ON A.MATNR = M.MATNR
         LEFT JOIN (SELECT * FROM V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(MATNR) ORDER BY MATNR) = 1) D
                ON TRY_TO_NUMBER(LEFT(A.MATNR::VARCHAR, 10)) = TRY_TO_NUMBER(D.MATNR)
         ORDER BY A.STORE_CODE, A.MATNR';
    EXECUTE IMMEDIATE :sql_text;

    -- Article keys = every non-day column of the raw copy (with / without STORE_CODE)
    SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
           LISTAGG(IFF(COLUMN_NAME = 'STORE_CODE', NULL, '"' || COLUMN_NAME || '"'), ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :st_art_keys, :art_keys
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
      AND NOT REGEXP_LIKE(COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_.+');

    ------------------------------------------------------------------------
    -- 2) MRST_ST_MAJ_CAT_TREND: store x MAJ_CAT + PSF (the store benchmark)
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.MRST_ST_MAJ_CAT_TREND
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrst_base, '{SRC}',
             '(SELECT SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT)') || ',
         DAYS AS (SELECT SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE)
         SELECT SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, FINAL_DENSITY, APF, PPA,
                ' || avg_cols || ',
                ' || day_names || '
         FROM DAYS
         ORDER BY SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT';
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 3) MRDC_MAJ_CAT_TREND: MAJ_CAT, stores summed + PSF (the MRDC benchmark)
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.MRDC_MAJ_CAT_TREND
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrdc_base, '{SRC}',
             '(SELECT SEG, DIV, SUB_DIV, MAJ_CAT, ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY SEG, DIV, SUB_DIV, MAJ_CAT)') || ',
         DAYS AS (SELECT SEG, DIV, SUB_DIV, MAJ_CAT, FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE)
         SELECT SEG, DIV, SUB_DIV, MAJ_CAT, FINAL_DENSITY, APF, PPA,
                ' || avg_cols || ',
                ' || day_names || '
         FROM DAYS
         ORDER BY SEG, DIV, SUB_DIV, MAJ_CAT';
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 4) MRST_ST_ART_TREND: store x article + PSF + benchmark (store + MAJ_CAT) + achievement + H/V
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.MRST_ST_ART_TREND
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrst_base, '{SRC}', 'V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND') || ',
         DAYS AS (SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE),
         P AS (SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA, ' || avg_cols || ', ' || day_names || ' FROM DAYS),
         J AS (SELECT P.*, ' || mc_cols || '
               FROM P
               LEFT JOIN V2RETAIL.SILVER.MRST_ST_MAJ_CAT_TREND M
                      ON P.STORE_CODE = M.STORE_CODE AND P.MAJ_CAT = M.MAJ_CAT),
         H AS (SELECT J.*, ' || pct_cols || ' FROM J)
         SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_names || ',
                ' || mc_names || ',
                ' || REPLACE(ach_t, '{PFX}', 'ST_MAJ_CAT_') || ',
                ' || hv_expr || ' AS ARTICLE_HV,
                ' || day_names || '
         FROM H
         ORDER BY STORE_CODE, MATNR';
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 5) MRDC_ART_TREND: article, stores summed + PSF + benchmark (MAJ_CAT) + achievement + H/V.
    --    The attributes depend only on MATNR, so grouping by all of them gives one row per MATNR.
    --    Built last: the skip check above reads it.
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE V2RETAIL.SILVER.MRDC_ART_TREND
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrdc_base, '{SRC}',
             '(SELECT ' || art_keys || ', ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY ' || art_keys || ')') || ',
         DAYS AS (SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE),
         P AS (SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA, ' || avg_cols || ', ' || day_names || ' FROM DAYS),
         J AS (SELECT P.*, ' || mc_cols || '
               FROM P
               LEFT JOIN V2RETAIL.SILVER.MRDC_MAJ_CAT_TREND M
                      ON P.MAJ_CAT = M.MAJ_CAT),
         H AS (SELECT J.*, ' || pct_cols || ' FROM J)
         SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_names || ',
                ' || mc_names || ',
                ' || REPLACE(ach_t, '{PFX}', 'MAJ_CAT_') || ',
                ' || hv_expr || ' AS ARTICLE_HV,
                ' || day_names || '
         FROM H
         ORDER BY SEG, DIV, SUB_DIV, MAJ_CAT, MATNR';
    EXECUTE IMMEDIATE :sql_text;

    RETURN 'Built up to ' || last_col || ' with space plan ' || sp ||
           ': STORE_ARTICLE_GRID_TREND, MRST_ST_MAJ_CAT_TREND, MRDC_MAJ_CAT_TREND, MRST_ST_ART_TREND, MRDC_ART_TREND';
END;
$$;

-- Build once now (the task does it every day after this):
CALL V2RETAIL.SILVER.USP_BUILD_TREND_GRID_TABLES();

-- Check against the old views (all must return 0 differences; pre-checked 2026-10-17: PPA sums equal,
-- MRST 1,804,097.60 / MRDC 5,058.52, benchmark joins one row per key).
-- MRST article: H/V, averages, achievement
-- SELECT COUNT(*) AS rows_old,
--        COUNT(N.MATNR) AS matched,
--        COUNT_IF(N.ARTICLE_HV <> O.ARTICLE_HV) AS hv_diff,
--        COUNT_IF(ABS(N.SALE_PSF_30D - O.SALE_PSF_30D) > 0.0001 OR ABS(N.GP_PSF_L7D - O.GP_PSF_L7D) > 0.0001
--              OR ABS(N.STR_MTD - O.STR_MTD) > 0.0001 OR ABS(N.MAJCAT_SALE_PSF_30D - O.MAJCAT_SALE_PSF_30D) > 0.0001) AS avg_diff,
--        COUNT_IF(N.ST_MAJ_CAT_30D_SALE_ACHIEVEMENT <> O.ST_MAJ_CAT_30D_SALE_ACHIEVEMENT
--              OR N.ST_MAJ_CAT_TD_GP_ACHIEVEMENT <> O.ST_MAJ_CAT_TD_GP_ACHIEVEMENT) AS ach_diff
-- FROM V2RETAIL.SILVER.V_ARTICLE_HV O
-- LEFT JOIN V2RETAIL.SILVER.MRST_ST_ART_TREND N ON N.STORE_CODE = O.STORE_CODE AND N.MATNR = O.MATNR;
-- MRDC article: same
-- SELECT COUNT(*) AS rows_old, COUNT(N.MATNR) AS matched,
--        COUNT_IF(N.ARTICLE_HV <> O.ARTICLE_HV) AS hv_diff,
--        COUNT_IF(ABS(N.SALE_PSF_30D - O.SALE_PSF_30D) > 0.0001 OR ABS(N.GP_PSF_L7D - O.GP_PSF_L7D) > 0.0001
--              OR ABS(N.STR_MTD - O.STR_MTD) > 0.0001 OR ABS(N.MAJCAT_SALE_PSF_30D - O.MAJCAT_SALE_PSF_30D) > 0.0001) AS avg_diff,
--        COUNT_IF(N.MAJ_CAT_30D_SALE_ACHIEVEMENT <> O.MAJ_CAT_30D_SALE_ACHIEVEMENT) AS ach_diff
-- FROM V2RETAIL.SILVER.V_MRDC_ARTICLE_HV O
-- LEFT JOIN V2RETAIL.SILVER.MRDC_ART_TREND N ON N.MATNR = O.MATNR;
-- MAJ_CAT tables: averages
-- SELECT COUNT(*), COUNT(N.MAJ_CAT),
--        COUNT_IF(ABS(N.SALE_PSF_30D - O.SALE_PSF_30D) > 0.0001 OR ABS(N.GP_PSF_TD - O.GP_PSF_TD) > 0.0001 OR ABS(N.STR_L7D - O.STR_L7D) > 0.0001)
-- FROM V2RETAIL.SILVER.V_MAJ_CAT_TREND_PSF_SUMMARY O
-- LEFT JOIN V2RETAIL.SILVER.MRST_ST_MAJ_CAT_TREND N ON N.STORE_CODE = O.STORE_CODE AND N.MAJ_CAT = O."MAJ-CAT";
-- SELECT COUNT(*), COUNT(N.MAJ_CAT),
--        COUNT_IF(ABS(N.SALE_PSF_30D - O.SALE_PSF_30D) > 0.0001 OR ABS(N.GP_PSF_TD - O.GP_PSF_TD) > 0.0001 OR ABS(N.STR_L7D - O.STR_L7D) > 0.0001)
-- FROM V2RETAIL.SILVER.V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID_PSF_SUMMARY O
-- LEFT JOIN V2RETAIL.SILVER.MRDC_MAJ_CAT_TREND N ON N.MAJ_CAT = O."MAJ-CAT";
