-- Step 4 (outputs): one procedure that builds any rollup of PROCESS_DATA_SALE_STK_L30_DAYS.
--
--   CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
--       'V2RETAIL.SILVER.V_MRST_TREND_MJ_MACRO_MVGR',          -- object to create
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
-- when it is created. USP_BUILD_TREND_REPORTS_DAILY holds one CALL per output and runs after step 2.
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
    OUTPUT_NAME  VARCHAR,              -- full name, e.g. 'V2RETAIL.SILVER.V_MRST_TREND_MJ'
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
CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_BUILD_TREND_REPORTS_DAILY()
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
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MC', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MC_CODE AS "MC-CD"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 2. SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 3. ...,MAJ_CAT,M_FAB_1
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_FAB', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", M_FAB_1 AS FABRIC',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 4. ...,MAJ_CAT,MACRO_MVGR
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_MACRO_MVGR', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", MACRO_MVGR AS "MACRO MVGR"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 5. ...,MAJ_CAT,MAIN_MVGR
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_MICRO_MVGR', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", MAIN_MVGR AS "MICRO MVGR"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 6. ...,MAJ_CAT,REG_SEG
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_RNG_SEG', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", REG_SEG AS "RNG-SEG"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 7. ...,MAJ_CAT,SIZE_1
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_SIZE', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", SIZE_1 AS "SIZE"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 8. ...,MAJ_CAT,M_FAB_MAIN_MVGR_1 (added 2026-10-13; from the broader menu, not DIM_PRODUCT_V2).
    --    ~7% of articles have no value (no broader-menu match or blank): shown as 'NA' so they are labelled.
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", COALESCE(NULLIF(TRIM(M_FAB_MAIN_MVGR_1), ''''), ''NA'') AS M_FAB_MAIN_MVGR_1',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 9-11 = the USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE reports (code from sp_helptext, 2026-10-14).
    -- SQL Server runs each one per ZONE / REG / DIV value (its 4th input, a WHERE filter, not an
    -- output column) to get smaller exports. Here: one view for all; the split is a WHERE when reading,
    -- e.g. SELECT * FROM ..._MRP WHERE ZONE = 'NORTH'. Its 3rd input (store codes) is also a WHERE.
    -- ZONE is added as a column (one zone per store, totals unchanged); NULL -> 'NA' so stores
    -- without a zone are kept (SQL Server's split files drop them).

    -- 9. ...,MAJ_CAT,COLOR (SQL Server splits by DIV, already a column). COLOR = P.COLOR_NEW (2026-10-14)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", COLOR_NEW AS COLOR',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 10. ...,MAJ_CAT,MRP (SQL Server splits by C.ZONE)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", COALESCE(C.ZONE, ''NA'') AS ZONE, STORE_CODE, MAJ_CAT AS "MAJ-CAT", MRP',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 11. ...,MAJ_CAT,MRP,REG_SEG (not in SQL Server's split list: whole report)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP_RNG_SEG', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", MRP, REG_SEG AS "RNG-SEG"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 12-14 = more _BY_REG_ZONE reports (added 2026-10-14). Column names as in their SQL Server calls
    -- (SUB_DIV / MAJ_CAT without hyphen here). The same REG codes exist in both zones (R10 = EAST R10
    -- and NORTH R10), so 12 has ZONE and REG; SQL Server's REG filter alone mixes both zones.

    -- 12. MRST_ST_GEN_ART_CLR: ...,MAJ_CAT,MC_CODE,STORE_CODE,GEN_ART_NUMBER,COLOR (SQL Server splits by C.REG)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_GEN_ART_CLR', 'VIEW',
        'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, COALESCE(C.ZONE, ''NA'') AS ZONE, COALESCE(C.REG, ''NA'') AS REG, STORE_CODE, GEN_ART_NUMBER AS "GEN-ART", COLOR_NEW AS CLR',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 13. MRST_ST_MAJ_M_VND_CD: ...,STORE_CODE,MAJ_CAT,MERGE_VENDOR_CODE (SQL Server splits by C.ZONE)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_M_VND_CD', 'VIEW',
        'SEG, DIV, SUB_DIV, COALESCE(C.ZONE, ''NA'') AS ZONE, STORE_CODE, MAJ_CAT, MERGE_VENDOR_CODE AS "M-VND-CD"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 14. MRST_ST_M_VND_CD: ...,STORE_CODE,MERGE_VENDOR_CODE (SQL Server splits by C.ZONE)
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_M_VND_CD', 'VIEW',
        'SEG, DIV, SUB_DIV, COALESCE(C.ZONE, ''NA'') AS ZONE, STORE_CODE, MERGE_VENDOR_CODE AS "M-VND-CD"',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');

    -- 15. SQL Server file MRST_TREND_ST_MJ_CLR_NOT_APP (USP_MRST_SAL_STK_L30_TREND_NOT_APP): report 9 without the
    --     APP segment, i.e. GM + MKT only. APP / GM / MKT are SEG values (DIV = KIDS, LADIES, LS, ...).
    CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT('V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR_NOT_APP', 'VIEW',
        'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT", COLOR_NEW AS COLOR',
        'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE'' AND P.SEG <> ''APP''');

    -- Earlier one-off view (all stores, blank MACRO_MVGR -> 'NA'); report 4 is the SQL Server version.
    -- CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
    --     'V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR', 'VIEW',
    --     'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COALESCE(NULLIF(TRIM(MACRO_MVGR), ''''), ''NA'') AS MACRO_MVGR');

    RETURN '15 L30 report views built';
END;
$$;

CALL V2RETAIL.SILVER.USP_BUILD_TREND_REPORTS_DAILY();


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
    CALL V2RETAIL.SILVER.USP_BUILD_TREND_REPORTS_DAILY();

DROP TASK IF EXISTS V2RETAIL.SILVER.TREND_L30_VIEWS;   -- old task from 10_
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR;   -- old view from 10_

-- Report views renamed V_L30_STORE_* -> V_MRST_TREND_* (2026-10-14). The old names are no longer
-- rebuilt and break on the next day's columns: drop them (once).
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MC;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_FABRIC;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MACRO_MVGR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MICRO_MVGR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_RNGSEG;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_SIZE;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_M_FAB_MAIN_MVGR_1;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_COLOR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MRP;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_MRP_RNGSEG;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_GEN_ART_CLR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_M_VND_CD;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_M_VND_CD;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_STORE_MAJCAT_COLOR_NOT_APP;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_COLOR;         -- leftovers from 2026-10-13
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_MRP;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_L30_REGZONE_MAJCAT_MRP_RNGSEG;

ALTER TASK V2RETAIL.SILVER.TREND_L30_OUTPUTS RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD    RESUME;

SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;


------------------------------------------------------------------------------
-- 4) Check an output: totals must equal the article table (WHERE-filtered outputs will be lower).
--    Replace the date with yesterday.
------------------------------------------------------------------------------
-- SELECT (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.V_MRST_TREND_MJ)                AS output_total,
--        (SELECT SUM("2026-10-12_SALE_V") FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) AS table_total;
