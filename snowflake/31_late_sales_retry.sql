-- One-off (2026-10-17): wait for yesterday's sales instead of loading without them.
--
-- On 2026-10-17 the 07:00 IST run found no FP sales for 10-16 in VBRP (they arrived between 08:00
-- and 09:00), so 10-16 had stock but zero sales and every TD PSF value was 0.
-- After this:
--   - the chain starts every hour 07:00-12:00 IST;
--   - step 1 fails while VBRP has no FP sales for yesterday (tables untouched, next hour retries);
--   - once a run has finished, steps 1 and 2 skip for the rest of the day.
--
-- Run the whole file in Snowsight as PROGRAMMER_DEV_ROLE, after re-running the CREATE PROCEDURE
-- statements of 01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql and 02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql.

USE ROLE PROGRAMMER_DEV_ROLE;

-- The schedule can only change while the root task is suspended
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SUSPEND;
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD SET SCHEDULE = 'USING CRON 0 7-12 * * * Asia/Kolkata';
ALTER TASK V2RETAIL.SILVER.TREND_L30_LOAD RESUME;

-- Check: schedule shows 0 7-12, all 4 tasks "started"
SHOW TASKS LIKE 'TREND_L30%' IN SCHEMA V2RETAIL.SILVER;

-- Try it now: 10-16's sales are already in the main table, so both steps should say "Skipped"
CALL V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST();
CALL V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS();
