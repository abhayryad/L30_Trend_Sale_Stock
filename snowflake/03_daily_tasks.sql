-- Daily automation: Task 1 runs on a schedule, each next task runs as soon as the previous one succeeds.
--   TREND_L30_LOAD    hourly 07:00-12:00 IST -> USP_GENERATE_L30D_STK_SALE_VQ_MRST (fills TREND_KPI_DATA)
--   TREND_L30_PIVOT   after LOAD  -> USP_PROCESS_DATA_SALE_STK_L30_DAYS         (rebuilds PROCESS_DATA_SALE_STK_L30_DAYS)
--   TREND_L30_MAJ_CAT  after PIVOT -> USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT  (rebuilds PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT)
--   TREND_L30_GRID    after PIVOT -> USP_BUILD_TREND_GRID_TABLES                (raw copy + the 4 MRST_* / MRDC_* PSF / H-V tables, 32_)
-- TREND_L30_PSF_VIEWS (after MAJ_CAT -> USP_REBUILD_PSF_VIEWS) still exists in Snowflake but is no longer
-- created here: the GRID tables replace the old PSF views, which are kept for a while and then dropped
-- together with that task by 33_drop_old_psf_views.sql.
-- If a task fails, the ones after it do not run, so yesterday's tables stay in place.
--
-- Hourly 07:00-12:00 (2026-10-17): LOAD fails while VBRP has no FP sales for yesterday, and the
-- next hour retries. Once a run has finished, LOAD, PIVOT and GRID skip for the rest of the day; MAJ_CAT
-- still runs each hour (under a minute). No sales by 12:00 = yesterday's tables stay for that day.
--
-- Time: on 2026-10-09 the sources were last updated at 03:57 IST (BRONZE.VBRP) and
-- 05:02 IST (BRONZE.ET_STOCK_DATA), so 07:00 IST leaves about 2 hours of margin.
--
-- Needs: the role creating the tasks must have EXECUTE TASK (account level, granted by
-- ACCOUNTADMIN). Tasks run as their owner role, which must be able to read the sources and
-- write to V2RETAIL.SILVER.

-- Snowflake has no ALTER TASK ... RENAME: to rename, create under the new name and drop the old one
-- (renamed 2026-10-13 from T_L30D_LOAD / T_L30D_PIVOT / T_L30D_MAJCAT).

USE ROLE PROGRAMMER_DEV_ROLE;   -- owner of the deployed tasks (all tasks in one chain need the same owner)

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_LOAD
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = 'USING CRON 0 7-12 * * * Asia/Kolkata'
    COMMENT   = 'L30D step 1: load TREND_KPI_DATA (stock + sales, last 31 days)'
AS
    CALL V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST();

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_PIVOT
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 2: rebuild PROCESS_DATA_SALE_STK_L30_DAYS'
    AFTER V2RETAIL.SILVER.TREND_L30_LOAD
AS
    CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS();

CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_MAJ_CAT
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 2b: rebuild PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT (MAJ_CAT x STORE_CODE)'
    AFTER V2RETAIL.SILVER.TREND_L30_PIVOT
AS
    CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT();

-- Added 2026-10-17: needs 32_trend_grid_tables.sql deployed first. Runs next to MAJ_CAT
-- (both only need PIVOT); skips once the tables already end on the main table's last day.
CREATE OR REPLACE TASK V2RETAIL.SILVER.TREND_L30_GRID
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 2c: rebuild STORE_ARTICLE_GRID_TREND + MRST_ST_ART_TREND, MRST_ST_MAJ_CAT_TREND, MRDC_ART_TREND, MRDC_MAJ_CAT_TREND'
    AFTER V2RETAIL.SILVER.TREND_L30_PIVOT
AS
    CALL V2RETAIL.SILVER.USP_BUILD_TREND_GRID_TABLES();

-- Tasks are created paused. Turn them on, children first
-- (to add a task to the running chain: SUSPEND TREND_L30_LOAD first, then create and resume):
ALTER TASK V2RETAIL.SILVER.TREND_L30_GRID RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_MAJ_CAT RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_PIVOT RESUME;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD  RESUME;

-- Check they are on (state = started) and see the next run time:
SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;

-- Run once now without waiting for the schedule (runs LOAD, then PIVOT, then MAJ_CAT and GRID):
-- EXECUTE TASK V2RETAIL.SILVER.TREND_L30_LOAD;

-- Did they run? (also shows scheduled / failed runs)
-- SELECT NAME, STATE, CONVERT_TIMEZONE('Asia/Kolkata', SCHEDULED_TIME) AS SCHEDULED_IST,
--        CONVERT_TIMEZONE('Asia/Kolkata', COMPLETED_TIME) AS COMPLETED_IST, ERROR_MESSAGE
-- FROM TABLE(V2RETAIL.INFORMATION_SCHEMA.TASK_HISTORY(
--          SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP())))
-- WHERE NAME IN ('TREND_L30_LOAD', 'TREND_L30_PIVOT', 'TREND_L30_MAJ_CAT', 'TREND_L30_GRID')
-- ORDER BY SCHEDULED_TIME DESC;

-- Pause (parent first; the others only run after LOAD anyway):
-- ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;

-- To change the time: suspend LOAD, ALTER TASK ... SET SCHEDULE = '...', resume LOAD.
