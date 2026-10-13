-- Step 4 (outputs): one procedure that builds any rollup of PROCESS_DATA_SALE_STK_L30_DAYS.
--
--   CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
--       'V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MACRO_MVGR',          -- object to create
--       'VIEW',                                                    -- 'VIEW' or 'TABLE'
--       'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MACRO_MVGR',      -- columns to group by
--       '');                                                       -- optional WHERE condition
--
-- Result: those columns + the 155 day/metric columns summed per group.
--
-- Columns available (always joined, LEFT JOIN, one row per key):
--   A  PROCESS_DATA_SALE_STK_L30_DAYS        MATNR, STORE_CODE (+ the day columns)
--   P  GOLD.DIM_PRODUCT_V2                   SEG, DIV, SUB_DIV, MAJ_CAT, MACRO_MVGR, ...
--   D  BRONZE.ET_ART_BROADER_MENU_DATA       M_* columns, matched on the 10-digit generic article
--   C  AKS_SILVER.SLV_MIS_STORE_MASTER       ZONE, REG, AREA, ST_STAT, ST_TYP, ...
-- SEG / DIV / SUB_DIV / MAJ_CAT are taken from P (same values as the article table, step 2 copies them).
-- A name that exists in two of them must be prefixed: M_YARN, M_YARN_02, M_BUYING_TYPE (P and D),
-- MATNR (A, P and D). Snowflake says "ambiguous column name" otherwise (checked 2026-10-13:
-- no other name is in more than one of them).
--
-- GROUP_COLS may contain expressions with AS, because the query uses GROUP BY ALL, e.g.
--   'STORE_CODE, MAJ_CAT, COALESCE(NULLIF(TRIM(MACRO_MVGR), ''''), ''NA'') AS MACRO_MVGR, D.M_YARN, C.ZONE'
-- Without that, articles with a blank / missing value are grouped under NULL.
-- WHERE_CLAUSE is plain SQL, e.g. 'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE'''.
--
-- Why rebuilt daily: the day columns get new names every day, and a view's column list is fixed
-- when it is created. USP_BUILD_L30_OUTPUTS_DAILY holds one CALL per output and runs after step 2.
--
-- EXECUTE AS CALLER: it runs with the rights of whoever calls it (the task: PROGRAMMER_DEV_ROLE),
-- so the WHERE text can't do more than the caller already can. The object is owned by that role.
-- COPY GRANTS keeps SELECT grants given to readers when the object is re-created.
-- Tested 2026-10-13 as a SELECT (store x MAJ_CAT x MACRO_MVGR x M_YARN x ZONE, ACT stores):
-- totals equal the article table, no rows multiplied by the joins.

USE ROLE PROGRAMMER_DEV_ROLE;   -- same owner as the tables, procedures and tasks


------------------------------------------------------------------------------
-- 1) The procedure
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
    OUTPUT_NAME  VARCHAR,              -- full name, e.g. 'V2RETAIL.SILVER.V_L30_STORE_MAJCAT'
    OBJECT_TYPE  VARCHAR,              -- 'VIEW' or 'TABLE'
    GROUP_COLS   VARCHAR,              -- 'SEG, STORE_CODE, MAJ_CAT, D.M_YARN'
    WHERE_CLAUSE VARCHAR DEFAULT ''    -- '' = no filter
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    cols     VARCHAR;
    sql_text VARCHAR;
    obj_type VARCHAR DEFAULT UPPER(TRIM(OBJECT_TYPE));
    bad_input EXCEPTION (-20001, 'OBJECT_TYPE must be VIEW or TABLE, GROUP_COLS must not be empty, and OUTPUT_NAME must not be a pipeline table.');
BEGIN
    IF (obj_type NOT IN ('VIEW', 'TABLE')
        OR TRIM(COALESCE(GROUP_COLS, '')) = ''
        OR UPPER(OUTPUT_NAME) ILIKE ANY ('%PROCESS_DATA_SALE_STK_L30_DAYS%', '%TREND_KPI_DATA%')) THEN
        RAISE bad_input;
    END IF;

    -- SUM(A."2026-09-12_STK_Q") AS "2026-09-12_STK_Q", ... for every day/metric column
    SELECT LISTAGG('SUM(A."' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE', 'SEG', 'DIV', 'SUB_DIV', 'MAJ_CAT');

    sql_text :=
        'CREATE OR REPLACE ' || IFF(obj_type = 'VIEW', 'VIEW ', 'TRANSIENT TABLE ') || OUTPUT_NAME || ' COPY GRANTS AS
         SELECT ' || GROUP_COLS || ', ' || cols || '
         FROM (SELECT * EXCLUDE (SEG, DIV, SUB_DIV, MAJ_CAT) FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) A
         LEFT JOIN (SELECT * FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(ARTICLE_NUMBER) ORDER BY MAJ_CAT) = 1) P
                ON A.MATNR = TRY_TO_NUMBER(P.ARTICLE_NUMBER)
         LEFT JOIN (SELECT * FROM V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(MATNR) ORDER BY MATNR) = 1) D
                ON TRY_TO_NUMBER(LEFT(A.MATNR::VARCHAR, 10)) = TRY_TO_NUMBER(D.MATNR)
         LEFT JOIN V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER C
                ON A.STORE_CODE = C.ST_CD
         ' || IFF(TRIM(COALESCE(WHERE_CLAUSE, '')) = '', '', 'WHERE ' || WHERE_CLAUSE) || '
         GROUP BY ALL';

    EXECUTE IMMEDIATE :sql_text;

    RETURN OUTPUT_NAME || ' (' || obj_type || ') created';
END;
$$;


------------------------------------------------------------------------------
-- 2) Your outputs: one CALL each. Run this procedure once now; the task runs it every day.
--    New output = add a CALL here, re-run this CREATE, and CALL it once.
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_L30_OUTPUTS_DAILY()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- Reports 1-7 = the SQL Server report calls (EXEC USP_MRST_SAL_STK_L30_TREND '<group by>', '<columns>'),
    -- report 8 is new in Snowflake. One view each.
    -- Same output column names as SQL Server ([SUB-DIV] -> "SUB-DIV" etc.), same active-store filter
    -- as procedure 05 (ST_STAT = 'ACT', ST_TYP = 'STORE'). Blank attribute values stay NULL, like SQL Server.

    -- 1. SEG,DIV,SUB_DIV,STORE_CODE,MC_CODE
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MC', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MC_CODE AS "MC-CD"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 2. SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 3. ...,MAJ_CAT,M_FAB_1
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_FABRIC', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", M_FAB_1 AS FABRIC',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 4. ...,MAJ_CAT,MACRO_MVGR
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MACRO_MVGR', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", MACRO_MVGR AS "MACRO MVGR"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 5. ...,MAJ_CAT,MAIN_MVGR
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MICRO_MVGR', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", MAIN_MVGR AS "MICRO MVGR"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 6. ...,MAJ_CAT,REG_SEG
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_RNGSEG', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", REG_SEG AS "RNG-SEG"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 7. ...,MAJ_CAT,SIZE_1
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_SIZE', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", SIZE_1 AS "SIZE"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 8. ...,MAJ_CAT,M_FAB_MAIN_MVGR_1 (added 2026-10-13; from the broader menu, not DIM_PRODUCT_V2).
    --    ~7% of articles have no value (no broader-menu match or blank): shown as 'NA' so they are labelled.
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_STORE_MAJCAT_M_FAB_MAIN_MVGR_1', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", COALESCE(NULLIF(TRIM(M_FAB_MAIN_MVGR_1), ''''), ''NA'') AS M_FAB_MAIN_MVGR_1',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- Later (not built yet): USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE reports.
    -- Assumed = same report + the store's ZONE and REG (its SQL Server code is not in
    -- sql_server_original/; confirm with sp_helptext). Its 3rd input is a STORE_CODE filter,
    -- '' in all calls so far (would go in the WHERE: AND A.STORE_CODE IN ('DB01','HB05')).

    -- _BY_REG_ZONE ...,MAJ_CAT,COLOR
    -- CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_COLOR', 'VIEW',
    --     'SEG, DIV, SUB_DIV AS "SUB-DIV", C.ZONE, C.REG, STORE_CODE, MAJ_CAT AS "MAJ-CAT", COLOR',
    --     'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- _BY_REG_ZONE ...,MAJ_CAT,MRP
    -- CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_MRP', 'VIEW',
    --     'SEG, DIV, SUB_DIV AS "SUB-DIV", C.ZONE, C.REG, STORE_CODE, MAJ_CAT AS "MAJ-CAT", MRP',
    --     'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- _BY_REG_ZONE ...,MAJ_CAT,MRP,REG_SEG
    -- CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_MRP_RNGSEG', 'VIEW',
    --     'SEG, DIV, SUB_DIV AS "SUB-DIV", C.ZONE, C.REG, STORE_CODE, MAJ_CAT AS "MAJ-CAT", MRP, REG_SEG AS "RNG-SEG"',
    --     'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- Earlier one-off view (all stores, blank MACRO_MVGR -> 'NA'); report 4 is the SQL Server version.
    -- CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
    --     'V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR', 'VIEW',
    --     'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COALESCE(NULLIF(TRIM(MACRO_MVGR), ''''), ''NA'') AS MACRO_MVGR');

    RETURN '8 L30 report views built';
END;
$$;

CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUTS_DAILY();


------------------------------------------------------------------------------
-- 3) Daily task after step 2. Replaces TREND_L30_VIEWS (10_), which rebuilt V_L30_SALE_STK_MACRO_MVGR.
--    That view is no longer rebuilt (report 4 replaces it): it breaks on the next day's columns, so drop it.
--    A task graph can only change while its root is suspended.
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_OUTPUTS
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 4: rebuild report views/tables on today''s columns'
    AFTER V2RETAIL.SILVER.TREND_L30_PIVOT
AS
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUTS_DAILY();

DROP TASK IF EXISTS V2RETAIL.SILVER.TREND_L30_VIEWS;   -- old task from 10_
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR;   -- old view from 10_

ALTER TASK V2RETAIL.SILVER.TREND_L30_OUTPUTS RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD    RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;


------------------------------------------------------------------------------
-- 4) Check an output: totals must equal the article table (WHERE-filtered outputs will be lower).
--    Replace the date with yesterday.
------------------------------------------------------------------------------
-- SELECT (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.V_L30_STORE_MAJCAT)           AS output_total,
--        (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) AS table_total;
