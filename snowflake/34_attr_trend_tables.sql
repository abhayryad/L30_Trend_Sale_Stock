-- Attribute trend tables (added 2026-10-19): the same PSF / H-V build as file 32, with one or more
-- article attributes added to the MAJ_CAT grouping. Each call builds 4 tables for one attribute set,
-- from the parent STORE_ARTICLE_GRID_TREND only (never from the MRST_* / MRDC_* tables of file 32):
--
--   CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND('COLOR');
--   CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND('M_FIT, COLOR');   -- combination: store x MAJ_CAT x COLOR x M_FIT
--
--   Table (V2RETAIL.SILVER), <SET> = the columns sorted and joined by '_' (e.g. COLOR_M_FIT)
--   MRST_ST_MAJ_CAT_<SET>_TREND   store x MAJ_CAT x attributes   the benchmark (no H/V), like MRST_ST_MAJ_CAT_TREND
--   MRDC_MAJ_CAT_<SET>_TREND      MAJ_CAT x attributes           the benchmark (no H/V), like MRDC_MAJ_CAT_TREND
--   MRST_ST_ART_<SET>_TREND       store x article                H/V vs its row in MRST_ST_MAJ_CAT_<SET>_TREND
--   MRDC_ART_<SET>_TREND          article, stores summed         H/V vs its row in MRDC_MAJ_CAT_<SET>_TREND
--
-- Same pattern as the 4 tables of file 32, the attributes added to the MAJ_CAT grouping. PSF, averages,
-- achievement and H/V bands: exactly as file 32. PPA is the same for every article of a store + MAJ_CAT
-- (MRST) or a MAJ_CAT (MRDC), so a group's area = its STK_Q x PPA and the groups add up to the
-- store x MAJ_CAT totals.
--
-- Columns, in order (only the chosen attributes, no other article attributes; user rule 2026-10-19):
--   group tables:   SEG, DIV, SUB_DIV, [STORE_CODE,] MAJ_CAT, <attributes>, FINAL_DENSITY, APF, PPA,
--                   averages, per-day columns
--   article tables: SEG, DIV, SUB_DIV, [STORE_CODE,] MAJ_CAT, MATNR, <attributes>, FINAL_DENSITY, APF, PPA,
--                   averages, <SET>_* benchmark averages, 8 achievement columns
--                   ST_MAJ_CAT_<SET>_<w>_<SALE|GP>_ACHIEVEMENT (MRST) / MAJ_CAT_<SET>_... (MRDC),
--                   ARTICLE_HV, per-day columns
--
-- Rules: 1-5 columns of STORE_ARTICLE_GRID_TREND, not a key (SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT,
-- MATNR) or day column; names checked against INFORMATION_SCHEMA, so nothing else reaches the SQL.
-- Each set built is recorded in TREND_ATTR_LIST and refreshed daily by TREND_L30_ATTR (35_attr_trend_daily.sql).
-- Attribute joins use EQUAL_NULL, so non-text attributes with NULLs still find their group.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the other tables, procedures and tasks

CREATE TABLE IF NOT EXISTS V2RETAIL.SILVER.TREND_ATTR_LIST (
    ATTR_SET    VARCHAR NOT NULL,        -- e.g. COLOR_M_FIT (table name part)
    ATTRS       VARCHAR NOT NULL,        -- e.g. COLOR, M_FIT
    ACTIVE      BOOLEAN DEFAULT TRUE,
    ADDED_ON    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_BUILT  TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_ATTR_TREND(ATTRS VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    set_name     VARCHAR;
    set_list     VARCHAR;
    a_cols       VARCHAR;
    a_join       VARCHAR;
    n_attr       INTEGER DEFAULT 0;
    n_ok         INTEGER DEFAULT 0;
    last_col     VARCHAR;
    last_day     DATE;
    sp           VARCHAR;
    sum_cols     VARCHAR;
    st_art_keys  VARCHAR;
    art_keys     VARCHAR;
    mrst_keys    VARCHAR;
    mrdc_keys    VARCHAR;
    day_cols     VARCHAR;
    day_names    VARCHAR;
    avg_cols     VARCHAR;
    avg_names    VARCHAR;
    mc_t         VARCHAR;
    mcn_t        VARCHAR;
    ach_t        VARCHAR;
    pct_t        VARCHAR;
    hv_t         VARCHAR;
    band_t       VARCHAR DEFAULT 'CASE WHEN {X} <= 25 THEN ''D'' WHEN {X} <= 50 THEN ''VV'' WHEN {X} <= 90 THEN ''V'' WHEN {X} <= 125 THEN ''N'' WHEN {X} <= 170 THEN ''H'' WHEN {X} <= 200 THEN ''HH'' ELSE ''G'' END';
    mrst_base    VARCHAR;
    mrdc_base    VARCHAR;
    t_mrst_mc    VARCHAR;
    t_mrdc_mc    VARCHAR;
    t_mrst_art   VARCHAR;
    t_mrdc_art   VARCHAR;
    sql_text     VARCHAR;
    bad_attr     EXCEPTION (-20402, 'Attributes must be 1-5 non-key, non-day columns of V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND.');
    no_plan      EXCEPTION (-20401, 'No SPACE_PLAN_<current month>_<timestamp> table with rows in V2RETAIL.AKS_GOLD.');
BEGIN
    ------------------------------------------------------------------------
    -- Attribute set: upper-cased, de-duplicated, sorted; every name must be a column of the parent
    ------------------------------------------------------------------------
    SELECT COUNT(*),
           COUNT(C.COLUMN_NAME),
           LISTAGG(A.N, '_') WITHIN GROUP (ORDER BY A.N),
           LISTAGG(A.N, ', ') WITHIN GROUP (ORDER BY A.N),
           LISTAGG('"' || A.N || '"', ', ') WITHIN GROUP (ORDER BY A.N),
           LISTAGG('EQUAL_NULL(P."' || A.N || '", M."' || A.N || '")', ' AND ') WITHIN GROUP (ORDER BY A.N)
    INTO :n_attr, :n_ok, :set_name, :set_list, :a_cols, :a_join
    FROM (SELECT DISTINCT UPPER(TRIM(VALUE)) AS N
          FROM TABLE(SPLIT_TO_TABLE(:ATTRS, ','))
          WHERE TRIM(VALUE) <> '') A
    LEFT JOIN V2RETAIL.INFORMATION_SCHEMA.COLUMNS C
           ON C.TABLE_SCHEMA = 'SILVER' AND C.TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
          AND C.COLUMN_NAME = A.N
          AND C.COLUMN_NAME NOT IN ('SEG', 'DIV', 'SUB_DIV', 'STORE_CODE', 'MAJ_CAT', 'MATNR')
          AND NOT REGEXP_LIKE(C.COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_.+');
    IF (n_attr = 0 OR n_attr > 5 OR n_ok <> n_attr) THEN
        RAISE bad_attr;
    END IF;

    t_mrst_mc  := 'V2RETAIL.SILVER.MRST_ST_MAJ_CAT_' || set_name || '_TREND';
    t_mrdc_mc  := 'V2RETAIL.SILVER.MRDC_MAJ_CAT_' || set_name || '_TREND';
    t_mrst_art := 'V2RETAIL.SILVER.MRST_ST_ART_' || set_name || '_TREND';
    t_mrdc_art := 'V2RETAIL.SILVER.MRDC_ART_' || set_name || '_TREND';
    mrst_keys  := 'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, ' || a_cols;
    mrdc_keys  := 'SEG, DIV, SUB_DIV, MAJ_CAT, ' || a_cols;
    st_art_keys := 'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MATNR, ' || a_cols;
    art_keys    := 'SEG, DIV, SUB_DIV, MAJ_CAT, MATNR, ' || a_cols;

    -- Last day in the parent, e.g. "2026-10-18_SALE_V"
    SELECT MAX(COLUMN_NAME) INTO :last_col
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
      AND ENDSWITH(COLUMN_NAME, '_SALE_V');
    last_day := TO_DATE(LEFT(last_col, 10));

    -- Space plan: same rule as file 32 (current month, IST; latest timestamp; not empty)
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
    -- Column lists (as file 32, read from the parent)
    ------------------------------------------------------------------------
    -- Day columns, summed for the groups
    SELECT LISTAGG('SUM("' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :sum_cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
      AND REGEXP_LIKE(COLUMN_NAME, '[0-9]{4}-[0-9]{2}-[0-9]{2}_.+');

    -- Per day: the 5 raw values, then FINAL_AREA / SALE_PSF / GP_PSF / STR (expressions and names)
    WITH DAYS AS (
        SELECT DISTINCT TO_DATE(LEFT(COLUMN_NAME, 10)) AS D
        FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
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

    -- Averages per KPI, in the order MTD, L7D, 30D, TD
    WITH DAYS AS (
        SELECT DISTINCT TO_DATE(LEFT(COLUMN_NAME, 10)) AS D
        FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = 'STORE_ARTICLE_GRID_TREND'
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

    -- Article tables: benchmark averages of the attribute group ({BM} = <SET>_, e.g. COLOR_SALE_PSF_30D)
    SELECT LISTAGG('COALESCE(M.' || K || '_' || W || ', 0) AS {BM}' || K || '_' || W, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD),
           LISTAGG('{BM}' || K || '_' || W, ', ') WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :mc_t, :mcn_t
    FROM (SELECT column1 AS K, column2 AS K_ORD FROM VALUES ('SALE_PSF', 1), ('GP_PSF', 2), ('STR', 3)) k
    CROSS JOIN (SELECT column1 AS W, column2 AS W_ORD FROM VALUES ('MTD', 1), ('L7D', 2), ('30D', 3), ('TD', 4)) w;

    -- Achievement: TD, MTD, L7D, 30D for SALE, then GP; {PFX} = column name prefix
    SELECT LISTAGG('TO_VARCHAR(ROUND(COALESCE(DIV0NULL(' || K || '_PSF_' || W || ', {BM}' || K || '_PSF_' || W ||
                   '), 0) * 100, 0)::INT) || ''%'' AS {PFX}' || W || '_' || K || '_ACHIEVEMENT', ', ')
               WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :ach_t
    FROM (SELECT column1 AS K, column2 AS K_ORD FROM VALUES ('SALE', 1), ('GP', 2)) k
    CROSS JOIN (SELECT column1 AS W, column2 AS W_ORD FROM VALUES ('TD', 1), ('MTD', 2), ('L7D', 3), ('30D', 4)) w;

    -- H/V: the 4 rounded achievements, banded; all four the same band = that band, else 'NA'
    pct_t := 'ROUND(COALESCE(DIV0NULL(SALE_PSF_30D, {BM}SALE_PSF_30D), 0) * 100, 0) AS P_SALE_30D, ' ||
             'ROUND(COALESCE(DIV0NULL(SALE_PSF_L7D, {BM}SALE_PSF_L7D), 0) * 100, 0) AS P_SALE_L7D, ' ||
             'ROUND(COALESCE(DIV0NULL(GP_PSF_30D,   {BM}GP_PSF_30D),   0) * 100, 0) AS P_GP_30D, ' ||
             'ROUND(COALESCE(DIV0NULL(GP_PSF_L7D,   {BM}GP_PSF_L7D),   0) * 100, 0) AS P_GP_L7D';
    hv_t := 'IFF(' || REPLACE(band_t, '{X}', 'P_SALE_30D') || ' = ' || REPLACE(band_t, '{X}', 'P_SALE_L7D') ||
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
    -- 1) MRST_ST_MAJ_CAT_<SET>_TREND: store x MAJ_CAT x attributes + PSF (the benchmark of table 3)
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE ' || t_mrst_mc || '
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrst_base, '{SRC}',
             '(SELECT ' || mrst_keys || ', ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY ' || mrst_keys || ')') || ',
         DAYS AS (SELECT ' || mrst_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE)
         SELECT ' || mrst_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_cols || ',
                ' || day_names || '
         FROM DAYS
         ORDER BY ' || mrst_keys;
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 2) MRDC_MAJ_CAT_<SET>_TREND: MAJ_CAT x attributes, stores summed + PSF (the benchmark of table 4)
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE ' || t_mrdc_mc || '
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrdc_base, '{SRC}',
             '(SELECT ' || mrdc_keys || ', ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY ' || mrdc_keys || ')') || ',
         DAYS AS (SELECT ' || mrdc_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE)
         SELECT ' || mrdc_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_cols || ',
                ' || day_names || '
         FROM DAYS
         ORDER BY ' || mrdc_keys;
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 3) MRST_ST_ART_<SET>_TREND: store x article (keys + chosen attributes), vs its row in table 1
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE ' || t_mrst_art || '
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrst_base, '{SRC}', 'V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND') || ',
         DAYS AS (SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE),
         P AS (SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA, ' || avg_cols || ', ' || day_names || ' FROM DAYS),
         J AS (SELECT P.*, ' || REPLACE(mc_t, '{BM}', set_name || '_') || '
               FROM P
               LEFT JOIN ' || t_mrst_mc || ' M
                      ON P.STORE_CODE = M.STORE_CODE AND P.MAJ_CAT = M.MAJ_CAT AND ' || a_join || '),
         H AS (SELECT J.*, ' || REPLACE(pct_t, '{BM}', set_name || '_') || ' FROM J)
         SELECT ' || st_art_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_names || ',
                ' || REPLACE(mcn_t, '{BM}', set_name || '_') || ',
                ' || REPLACE(REPLACE(ach_t, '{BM}', set_name || '_'), '{PFX}', 'ST_MAJ_CAT_' || set_name || '_') || ',
                ' || hv_t || ' AS ARTICLE_HV,
                ' || day_names || '
         FROM H
         ORDER BY STORE_CODE, MATNR';
    EXECUTE IMMEDIATE :sql_text;

    ------------------------------------------------------------------------
    -- 4) MRDC_ART_<SET>_TREND: article, stores summed (keys + chosen attributes), vs its row in table 2
    ------------------------------------------------------------------------
    sql_text :=
        'CREATE OR REPLACE TRANSIENT TABLE ' || t_mrdc_art || '
             DATA_RETENTION_TIME_IN_DAYS = 0 COPY GRANTS AS
         WITH ' || REPLACE(mrdc_base, '{SRC}',
             '(SELECT ' || art_keys || ', ' || sum_cols || '
               FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND
               GROUP BY ' || art_keys || ')') || ',
         DAYS AS (SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA, ' || day_cols || ' FROM BASE),
         P AS (SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA, ' || avg_cols || ', ' || day_names || ' FROM DAYS),
         J AS (SELECT P.*, ' || REPLACE(mc_t, '{BM}', set_name || '_') || '
               FROM P
               LEFT JOIN ' || t_mrdc_mc || ' M
                      ON P.MAJ_CAT = M.MAJ_CAT AND ' || a_join || '),
         H AS (SELECT J.*, ' || REPLACE(pct_t, '{BM}', set_name || '_') || ' FROM J)
         SELECT ' || art_keys || ', FINAL_DENSITY, APF, PPA,
                ' || avg_names || ',
                ' || REPLACE(mcn_t, '{BM}', set_name || '_') || ',
                ' || REPLACE(REPLACE(ach_t, '{BM}', set_name || '_'), '{PFX}', 'MAJ_CAT_' || set_name || '_') || ',
                ' || hv_t || ' AS ARTICLE_HV,
                ' || day_names || '
         FROM H
         ORDER BY SEG, DIV, SUB_DIV, MAJ_CAT, MATNR';
    EXECUTE IMMEDIATE :sql_text;

    -- Remember the set (for the daily refresh)
    MERGE INTO V2RETAIL.SILVER.TREND_ATTR_LIST L
    USING (SELECT :set_name AS ATTR_SET, :set_list AS ATTRS) S
       ON L.ATTR_SET = S.ATTR_SET
    WHEN MATCHED THEN UPDATE SET L.LAST_BUILT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (ATTR_SET, ATTRS, LAST_BUILT) VALUES (S.ATTR_SET, S.ATTRS, CURRENT_TIMESTAMP());

    RETURN 'Built ' || set_name || ' up to ' || last_col || ' with space plan ' || sp || ': ' ||
           t_mrst_mc || ', ' || t_mrdc_mc || ', ' || t_mrst_art || ', ' || t_mrdc_art;
END;
$$;

-- Build the first set:
CALL V2RETAIL.SILVER.USP_BUILD_ATTR_TREND('COLOR');

-- Checks (set COLOR):
-- 1) Group table summed back = store x MAJ_CAT from the parent (last day area and sale):
-- WITH G AS (SELECT STORE_CODE, MAJ_CAT, SUM("<day>_SALE_V") AS S, SUM(FINAL_AREA_<day>) AS A
--            FROM V2RETAIL.SILVER.MRST_ST_MAJ_CAT_COLOR_TREND GROUP BY 1, 2),
--      R AS (SELECT STORE_CODE, MAJ_CAT, SUM("<day>_SALE_V") AS S FROM V2RETAIL.SILVER.STORE_ARTICLE_GRID_TREND GROUP BY 1, 2)
-- SELECT COUNT(*), COUNT_IF(ABS(G.S - R.S) > 0.01) FROM R LEFT JOIN G USING (STORE_CODE, MAJ_CAT);
-- 2) Every article finds its group (no 0 benchmark from a missed join):
-- SELECT COUNT(*), COUNT_IF(M.STORE_CODE IS NULL) FROM V2RETAIL.SILVER.MRST_ST_ART_COLOR_TREND A
-- LEFT JOIN V2RETAIL.SILVER.MRST_ST_MAJ_CAT_COLOR_TREND M USING (STORE_CODE, MAJ_CAT, COLOR);
