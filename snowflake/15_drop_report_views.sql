-- One-off: remove step 4 (the daily report views). USP_TREND_REPORT (13_) replaces them.
--
-- Checked 2026-10-15 before writing this:
--   - V_MRST_TREND_MJ and V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1 equal the USP_TREND_REPORT query for the
--     same columns, row by row (183,544 and 419,226 rows, 0 differences).
--   - The colour / size views differ on purpose: they use DIM_PRODUCT_V2 colour names (JET BLACK),
--     USP_TREND_REPORT uses VW_PRODUCT_MASTER codes (JET_BLK). Totals are the same.
--   - Last 14 days: the views were only read by hand (no service user, Excel or Power BI).
--   - The old V_L30_* views and the 10_ objects (TREND_L30_VIEWS, V_L30_SALE_STK_MACRO_MVGR,
--     USP_CREATE_V_L30_SALE_STK_MACRO_MVGR) no longer exist, so they are not dropped here.
--
-- Run the whole file in Snowsight. Afterwards the daily chain is LOAD -> PIVOT -> MAJ_CAT.
-- To bring the views back: re-run 11_output_builder.sql and 12_run_mrst_rename.sql.

USE ROLE PROGRAMMER_DEV_ROLE;   -- owner of the tasks, views and procedures


------------------------------------------------------------------------------
-- 1) The task: a child task can only be dropped while the root task is suspended
------------------------------------------------------------------------------
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

DROP TASK IF EXISTS V2RETAIL.SILVER.TREND_L30_OUTPUTS;

-- The other children (PIVOT, MAJ_CAT) stay resumed, so resuming the root is enough.
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD RESUME;


------------------------------------------------------------------------------
-- 2) The 15 report views
------------------------------------------------------------------------------
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MC;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_FAB;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_MACRO_MVGR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_MICRO_MVGR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_RNG_SEG;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_SIZE;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP_RNG_SEG;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_GEN_ART_CLR;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_M_VND_CD;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_M_VND_CD;
DROP VIEW IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR_NOT_APP;


------------------------------------------------------------------------------
-- 3) The builder procedures
------------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS V2RETAIL.SILVER.USP_BUILD_TREND_REPORTS_DAILY();
DROP PROCEDURE IF EXISTS V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(VARCHAR, VARCHAR, VARCHAR, VARCHAR);


------------------------------------------------------------------------------
-- 4) Check
------------------------------------------------------------------------------
-- Expect 3 tasks (LOAD started, PIVOT and MAJ_CAT started), no TREND_L30_OUTPUTS:
SHOW TASKS LIKE 'TREND_L30_%' IN SCHEMA V2RETAIL.SILVER;

-- Expect 0 and 0:
SELECT (SELECT COUNT(*) FROM V2RETAIL.INFORMATION_SCHEMA.VIEWS
        WHERE TABLE_SCHEMA = 'SILVER' AND STARTSWITH(TABLE_NAME, 'V_MRST_TREND_')) AS VIEWS_LEFT,
       (SELECT COUNT(*) FROM V2RETAIL.INFORMATION_SCHEMA.PROCEDURES
        WHERE PROCEDURE_SCHEMA = 'SILVER' AND STARTSWITH(PROCEDURE_NAME, 'USP_BUILD_')) AS PROCS_LEFT;
