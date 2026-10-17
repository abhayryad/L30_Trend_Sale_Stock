-- Daily rebuild of the 8 PSF-chain views whose columns are named by date, so their dates follow
-- the last date in PROCESS_DATA_SALE_STK_L30_DAYS. Replaces the hard-coded files 18, 19, 24, 25.
--
--   CALL V2RETAIL.SILVER.USP_REBUILD_PSF_VIEWS();        -- rebuild all 8
--   CALL V2RETAIL.SILVER.USP_REBUILD_PSF_VIEWS('SQL');   -- only return the PSF views' SQL (nothing created)
--
-- 1) The 4 base grid views, with the same USP_TREND_REPORT calls that first made them
--    (taken from their definitions on 2026-10-17; until then these calls were not saved):
--      V_TREND_30_DAYS_GRID                article x store
--      V_MAJ_CAT_TREND                     store x MAJ-CAT
--      V_MRDC_TREND_30_DAYS_GRID           article, all stores
--      V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID   MAJ-CAT, all stores
-- 2) The 4 PSF views on top of them, same logic as files 18 / 19 / 24 / 25:
--      PPA               store:  "FINAL DENSITY" (store + MAJ-CAT) / MAX(APF) of the store
--                        MRDC:   AVG("FINAL DENSITY") of the MAJ-CAT / 22
--      FINAL_AREA_<day>  = STK_Q * PPA
--      SALE_PSF_<day>    = SALE_V / FINAL_AREA
--      GP_PSF_<day>      = SALE_GM / FINAL_AREA
--      STR_<day>         = STK_V / (SALE_V - SALE_GM)
--    Averages, counted relative to the last date D (only days with a value > 0 count:
--    sum of those days / number of those days, 0 when there are none):
--      <KPI>_MTD = 1st of D's month .. D     <KPI>_L7D = D-6 .. D
--      <KPI>_30D = D-29 .. D                 <KPI>_TD  = D
--    Missing values and divide-by-zero come out as 0, never NULL.
--
-- The views of files 20-23 and 26-29 name no dates, so they keep working and are not rebuilt here.
-- Runs daily as task TREND_L30_PSF_VIEWS after TREND_L30_MAJ_CAT (03_daily_tasks.sql).
-- EXECUTE AS CALLER, like USP_TREND_REPORT: the task's role (PROGRAMMER_DEV_ROLE) must own the 8 views.
-- COPY GRANTS keeps readers' SELECT grants when a view is re-created.
--
-- Checked 2026-10-17 before writing this (read-only):
--   - Run with the old days (2026-09-15 .. 2026-10-15), the generated per-day and average columns are
--     identical to files 18, 19, 24 and 25 (same MD5 after whitespace is collapsed).
--   - The 4 USP_TREND_REPORT calls give the same column expressions and sort as the live base views.
--
-- Run the whole file in Snowsight, once. Section 0 needs ACCOUNTADMIN, the rest PROGRAMMER_DEV_ROLE.


------------------------------------------------------------------------------
-- 0) One-off: hand the store chain and the 2 MRDC base views to PROGRAMMER_DEV_ROLE.
--    They were created as ACCOUNTADMIN; the daily task runs as PROGRAMMER_DEV_ROLE and can only
--    re-create views it owns. The rest of the MRDC chain is already PROGRAMMER_DEV_ROLE's, so after
--    this both chains have one owner. COPY CURRENT GRANTS keeps existing SELECT grants.
------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_TREND_30_DAYS_GRID              TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_MAJ_CAT_TREND                   TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_MRDC_TREND_30_DAYS_GRID         TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_TREND_30_DAYS_GRID_PSF          TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_MAJ_CAT_TREND_PSF               TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_TREND_30_DAYS_GRID_PSF_SUMMARY  TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_MAJ_CAT_TREND_PSF_SUMMARY       TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_ARTICLE_MAJCAT_PSF              TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_ARTICLE_MAJCAT_PSF_ACH          TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON VIEW V2RETAIL.SILVER.V_ARTICLE_HV                      TO ROLE PROGRAMMER_DEV_ROLE COPY CURRENT GRANTS;


------------------------------------------------------------------------------
-- 1) The procedure
------------------------------------------------------------------------------
USE ROLE PROGRAMMER_DEV_ROLE;

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_REBUILD_PSF_VIEWS(MODE VARCHAR DEFAULT 'RUN')
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    space_plan VARCHAR DEFAULT 'V2RETAIL.AKS_GOLD.SPACE_PLAN_OCT_20261007_142428';
    last_day   DATE;
    n_days     INTEGER;
    day_cols   VARCHAR;
    avg_cols   VARCHAR;
    base_cte   VARCHAR;
    sql_text   VARCHAR;
    all_sql    VARCHAR DEFAULT '';
    done       VARCHAR DEFAULT '';
    run_it     BOOLEAN DEFAULT (UPPER(TRIM(COALESCE(MODE, 'RUN'))) <> 'SQL');
    no_days    EXCEPTION (-20201, 'PROCESS_DATA_SALE_STK_L30_DAYS has no date columns.');
    c1 CURSOR FOR
        SELECT column1 AS VIEW_NAME, column2 AS SRC, column3 AS DIMS, column4 AS KIND
        FROM VALUES
            ('V_TREND_30_DAYS_GRID_PSF', 'V_TREND_30_DAYS_GRID',
             'SEG, DIV, "SUB-DIV", STORE_CODE, MATNR, "MAJ-CAT", "MC-CD", SIZE, COLOR, M_FAB_MAIN_MVGR_1, M_FAB_MAIN_MVGR_2, M_FIT, "M-VND-CD", MRP, REG_SEG',
             'STORE'),
            ('V_MAJ_CAT_TREND_PSF', 'V_MAJ_CAT_TREND',
             'SEG, DIV, "SUB-DIV", STORE_CODE, "MAJ-CAT"',
             'STORE'),
            ('V_MRDC_TREND_30_DAYS_GRID_PSF', 'V_MRDC_TREND_30_DAYS_GRID',
             'SEG, DIV, "SUB-DIV", MATNR, "MAJ-CAT", "MC-CD", SIZE, COLOR, M_FAB_MAIN_MVGR_1, M_FAB_MAIN_MVGR_2, M_FIT, "M-VND-CD", MRP, REG_SEG',
             'MRDC'),
            ('V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID_PSF', 'V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID',
             'SEG, DIV, "SUB-DIV", "MAJ-CAT"',
             'MRDC');
BEGIN
    -- The days, read from the main table's column names ("2026-10-16_STK_Q" -> 2026-10-16)
    CREATE OR REPLACE TEMPORARY TABLE PSF_DAYS AS
    SELECT DISTINCT TO_DATE(LEFT(COLUMN_NAME, 10)) AS D
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND REGEXP_LIKE(COLUMN_NAME, '\\d{4}-\\d{2}-\\d{2}_.+');

    SELECT MAX(D), COUNT(*) INTO :last_day, :n_days FROM PSF_DAYS;
    IF (n_days = 0) THEN RAISE no_days; END IF;

    -- 1) Base grid views on today's columns
    IF (run_it) THEN
        CALL V2RETAIL.SILVER.USP_TREND_REPORT(
            'SEG, DIV, SUB_DIV, STORE_CODE, MATNR, MAJ_CAT, MC_CODE, SIZE, COLOR, M_FAB_MAIN_MVGR_1, M_FAB_MAIN_MVGR_2, M_FIT, M_VND_CD, MRP, REG_SEG',
            '', '', 'V2RETAIL.SILVER.V_TREND_30_DAYS_GRID', 'VIEW',
            'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');
        CALL V2RETAIL.SILVER.USP_TREND_REPORT(
            'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT',
            '', '', 'V2RETAIL.SILVER.V_MAJ_CAT_TREND', 'VIEW',
            'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');
        CALL V2RETAIL.SILVER.USP_TREND_REPORT(
            'SEG, DIV, SUB_DIV, MATNR, MAJ_CAT, MC_CODE, SIZE, COLOR, M_FAB_MAIN_MVGR_1, M_FAB_MAIN_MVGR_2, M_FIT, M_VND_CD, MRP, REG_SEG',
            '', '', 'V2RETAIL.SILVER.V_MRDC_TREND_30_DAYS_GRID', 'VIEW',
            'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');
        CALL V2RETAIL.SILVER.USP_TREND_REPORT(
            'SEG, DIV, SUB_DIV, MAJ_CAT',
            '', '', 'V2RETAIL.SILVER.V_MRDC_TREND_MAJ_CAT_30_DAYS_GRID', 'VIEW',
            'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');
        done := '4 base views';
    END IF;

    -- 2) PSF views. Per day: the 5 raw values, then FINAL_AREA / SALE_PSF / GP_PSF / STR
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
               '{D}', TO_CHAR(D, 'YYYY-MM-DD')), '{S}', TO_CHAR(D, 'YYYY_MM_DD')), ',\n       ')
           WITHIN GROUP (ORDER BY D)
    INTO :day_cols
    FROM PSF_DAYS;

    -- Averages per KPI, in the order MTD, L7D, 30D, TD (same as files 18 / 19 / 24 / 25)
    SELECT LISTAGG(EXPR, ',\n       ') WITHIN GROUP (ORDER BY K_ORD, W_ORD)
    INTO :avg_cols
    FROM (
        SELECT k.K_ORD, w.W_ORD,
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
        JOIN PSF_DAYS d
          ON (w.W = 'MTD' AND d.D >= DATE_TRUNC('MONTH', :last_day))
          OR (w.W = 'L7D' AND d.D >  DATEADD(DAY, -7, :last_day))
          OR (w.W = '30D' AND d.D >  DATEADD(DAY, -30, :last_day))
          OR (w.W = 'TD'  AND d.D =  :last_day)
        GROUP BY k.K, k.K_ORD, w.W, w.W_ORD
    );

    FOR v IN c1 DO
        IF (v.KIND = 'STORE') THEN
            base_cte := 'SP AS (
    SELECT ST_CD, MAX(APF) AS APF
    FROM ' || space_plan || '
    GROUP BY ST_CD
),
BASE AS (
    SELECT COALESCE(D."FINAL DENSITY", 0) AS FINAL_DENSITY,
           COALESCE(S.APF, 0)             AS APF,
           COALESCE(DIV0NULL(D."FINAL DENSITY", S.APF), 0) AS PPA,
           A.*
    FROM V2RETAIL.SILVER.' || v.SRC || ' A
    LEFT JOIN SP S
           ON A.STORE_CODE = S.ST_CD
    LEFT JOIN ' || space_plan || ' D
           ON A.STORE_CODE = D.ST_CD
          AND A."MAJ-CAT"  = D.MAJ_CAT
)';
        ELSE
            base_cte := 'SP AS (
    SELECT MAJ_CAT, AVG("FINAL DENSITY") AS FINAL_DENSITY
    FROM ' || space_plan || '
    GROUP BY MAJ_CAT
),
BASE AS (
    SELECT COALESCE(S.FINAL_DENSITY, 0)  AS FINAL_DENSITY,
           22                            AS APF,
           COALESCE(S.FINAL_DENSITY, 0) / 22 AS PPA,
           A.*
    FROM V2RETAIL.SILVER.' || v.SRC || ' A
    LEFT JOIN SP S
           ON A."MAJ-CAT" = S.MAJ_CAT
)';
        END IF;

        sql_text := 'CREATE OR REPLACE VIEW V2RETAIL.SILVER.' || v.VIEW_NAME || ' COPY GRANTS AS
WITH ' || base_cte || ',
DAYS AS (
SELECT ' || v.DIMS || ',
       FINAL_DENSITY, APF, PPA,
       ' || day_cols || '
FROM BASE
)
SELECT ' || v.DIMS || ',
       FINAL_DENSITY, APF, PPA,
       ' || avg_cols || ',
       D.* EXCLUDE (' || v.DIMS || ', FINAL_DENSITY, APF, PPA)
FROM DAYS D';

        IF (run_it) THEN
            EXECUTE IMMEDIATE :sql_text;
        ELSE
            all_sql := all_sql || sql_text || ';\n\n';
        END IF;
    END FOR;

    IF (NOT run_it) THEN
        RETURN all_sql;
    END IF;
    RETURN done || ' + 4 PSF views rebuilt for ' || n_days || ' days ending ' || TO_CHAR(last_day, 'YYYY-MM-DD');
END;
$$;


------------------------------------------------------------------------------
-- 2) Run once now: the views move to today's days and the HV views work again
------------------------------------------------------------------------------
CALL V2RETAIL.SILVER.USP_REBUILD_PSF_VIEWS();

SELECT COUNT(*) FROM V2RETAIL.SILVER.V_ARTICLE_HV;
SELECT COUNT(*) FROM V2RETAIL.SILVER.V_MRDC_ARTICLE_HV;


------------------------------------------------------------------------------
-- 3) Daily: new task after TREND_L30_MAJ_CAT (also in 03_daily_tasks.sql).
--    A task graph can only change while its root is suspended.
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_PSF_VIEWS
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 3: rebuild the PSF-chain views on today''s days'
    AFTER V2RETAIL.SILVER.TREND_L30_MAJ_CAT
AS
    CALL V2RETAIL.SILVER.USP_REBUILD_PSF_VIEWS();

ALTER TASK V2RETAIL.SILVER.TREND_L30_PSF_VIEWS RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD      RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;   -- all 4 "started"
