-- Daily automation: Task 1 runs on a schedule, each next task runs as soon as the previous one succeeds.
--   T_L30D_LOAD    07:00 IST   -> USP_GENERATE_L30D_STK_SALE_VQ_MRST         (fills TREND_KPI_DATA)
--   T_L30D_PIVOT   after LOAD  -> USP_PROCESS_DATA_SALE_STK_L30_DAYS         (rebuilds PROCESS_DATA_SALE_STK_L30_DAYS)
--   T_L30D_MAJCAT  after PIVOT -> USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT  (rebuilds PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT)
-- If a task fails, the ones after it do not run, so yesterday's tables stay in place.
--
-- Time: on 2026-10-09 the sources were last updated at 03:57 IST (BRONZE.VBRP) and
-- 05:02 IST (BRONZE.ET_STOCK_DATA), so 07:00 IST leaves about 2 hours of margin.
--
-- Needs: the role creating the tasks must have EXECUTE TASK (account level, granted by
-- ACCOUNTADMIN). Tasks run as their owner role, which must be able to read the sources and
-- write to V2RETAIL.SILVER.

USE ROLE DATA_PLATFORM_ADMIN;

CREATE OR REPLACE TASK V2RETAIL.SILVER.T_L30D_LOAD
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = 'USING CRON 0 7 * * * Asia/Kolkata'
    COMMENT   = 'L30D step 1: load TREND_KPI_DATA (stock + sales, last 31 days)'
AS
    CALL V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST();

CREATE OR REPLACE TASK V2RETAIL.SILVER.T_L30D_PIVOT
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 2: rebuild PROCESS_DATA_SALE_STK_L30_DAYS'
    AFTER V2RETAIL.SILVER.T_L30D_LOAD
AS
    CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS();

CREATE OR REPLACE TASK V2RETAIL.SILVER.T_L30D_MAJCAT
    WAREHOUSE = COMPUTE_WH
    COMMENT   = 'L30D step 2b: rebuild PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT (MAJ_CAT x STORE_CODE)'
    AFTER V2RETAIL.SILVER.T_L30D_PIVOT
AS
    CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT();

-- Tasks are created paused. Turn them on, children first:
ALTER TASK V2RETAIL.SILVER.T_L30D_MAJCAT RESUME;
ALTER TASK V2RETAIL.SILVER.T_L30D_PIVOT RESUME;
ALTER TASK V2RETAIL.SILVER.T_L30D_LOAD  RESUME;

-- Check they are on (state = started) and see the next run time:
SHOW TASKS LIKE 'T_L30D%' IN SCHEMA V2RETAIL.SILVER;

-- Run once now without waiting for the schedule (runs LOAD, then PIVOT, then MAJCAT):
-- EXECUTE TASK V2RETAIL.SILVER.T_L30D_LOAD;

-- Did they run? (also shows scheduled / failed runs)
-- SELECT NAME, STATE, CONVERT_TIMEZONE('Asia/Kolkata', SCHEDULED_TIME) AS SCHEDULED_IST,
--        CONVERT_TIMEZONE('Asia/Kolkata', COMPLETED_TIME) AS COMPLETED_IST, ERROR_MESSAGE
-- FROM TABLE(V2RETAIL.INFORMATION_SCHEMA.TASK_HISTORY(
--          SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP())))
-- WHERE NAME IN ('T_L30D_LOAD', 'T_L30D_PIVOT', 'T_L30D_MAJCAT')
-- ORDER BY SCHEDULED_TIME DESC;

-- Pause (parent first; the others only run after LOAD anyway):
-- ALTER TASK V2RETAIL.SILVER.T_L30D_LOAD SUSPEND;

-- To change the time: suspend LOAD, ALTER TASK ... SET SCHEDULE = '...', resume LOAD.
