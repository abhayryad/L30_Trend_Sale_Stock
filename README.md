# L30D Sale & Stock: SQL Server → Snowflake

Moving the daily "last 30 days stock + sale" process from SQL Server (`DataV2`) to Snowflake.

## What it produces

**`PROCESS_DATA_SALE_STK_L30_DAYS`**: one row per article (`MATNR`) per store (`STORE_CODE`),
with 5 numbers for each of the last 31 days (yesterday-30 .. yesterday):

| Metric | Meaning |
|---|---|
| `STK_Q` | Stock quantity (LGORT 0001 + 0006) |
| `STK_V` | Stock value |
| `SALE_Q` | Sale quantity |
| `SALE_V` | Sale value |
| `SALE_GM` | Gross margin = `NETWR - WAVWR` (was `GM` = `SALE_VAL - NET_MAP` in SQL Server) |

Columns are named `<YYYY-MM-DD>_<METRIC>`, e.g. `2026-09-04_STK_Q`, which gives 2 keys + 155 value columns.
Many reports join this table to other tables.

## Flow

```
SQL Server:  ET_STOCK_DATA_LOG + ET_STOCK_DATA (stock), VIEW_ET_SALES_DATA (sales)
Snowflake:   V2RETAIL.BRONZE.ET_STOCK_DATA (stock), V2RETAIL.BRONZE.VBRP, FKART_ANA='FP' (sales)

ET_STOCK_DATA ─┐
VBRP (FP)     ─┴─► USP_GENERATE_L30D_STK_SALE_VQ_MRST ─► TREND_KPI_DATA ─► USP_PROCESS_DATA_SALE_STK_L30_DAYS ─► PROCESS_DATA_SALE_STK_L30_DAYS ─► reports
                     (loader, long format)                (staging)          (pivot to wide)                       (final)
```

## Tables

| Object | Role | Columns used | Snowflake status |
|---|---|---|---|
| `ET_STOCK_DATA_LOG` + `ET_STOCK_DATA` | Source: stock. In SQL Server, `ET_STOCK_DATA` was staging that got moved into `_LOG` | MATNR, WERKS, STOCK_DATE, LGORT, LABST, LABST_DMBTR | **Confirmed by user:** both → `V2RETAIL.BRONZE.ET_STOCK_DATA` (one table). Loader updated. |
| `VIEW_ET_SALES_DATA` | Source: sales (a **view**) | ARTICLE_NUMBER, STORE_CODE, SALES_DATE, SALE_QTY, SALE_VAL, NET_MAP | **Confirmed by user (2026-10-06):** → `V2RETAIL.BRONZE.VBRP` with `FKART_ANA = 'FP'`. SALES_DATE=`FKDAT_ANA` ('YYYYMMDD' text), SALE_QTY=`FKIMG`, SALE_VAL=`NETWR`, SALE_GM=`NETWR - WAVWR`, article/store `MATNR`/`WERKS`. (Earlier: `SILVER.V_VBRP` / `PRSDT`, replaced 2026-10-06.) Loader updated. |
| `TREND_KPI_DATA` | Staging, must be created once | MATNR, STORE_CODE, DATES, PARTICULARS_NAME, PARTICULARS_VALUE | Create with `snowflake/00_...` |
| `PROCESS_DATA_SALE_STK_L30_DAYS` | Final output, rebuilt daily | MATNR, STORE_CODE + 155 | Created by procedure 2 |

### Snowflake findings (2026-10-05)

Connected as `ABHAY_YADAV` / role `DATA_PLATFORM_ADMIN` / warehouse `COMPUTE_WH`, account `OZ95041`.

- `V2RETAIL.BRONZE.ET_STOCK_DATA` holds **daily history** (40 days checked, 2026-08-26 to 2026-10-04), with
  MATNR / WERKS / LGORT / LABST / LABST_DMBTR / STOCK_DATE (timestamp). It can likely replace **both**
  `ET_STOCK_DATA_LOG` and `ET_STOCK_DATA`, which also removes the double-count risk. No `ET_STOCK_DATA_LOG` in Snowflake.
- No `VIEW_ET_SALES_DATA` in Snowflake. Best candidate: `V2RETAIL.BRONZE.DAY_WISE_ST_VAR_SALE`
  (DT, ST_CD, ARTICLE_NUMBER, SALE_Q, SALE_V, GM_V). It has 30 of the 31 days for 2026-09-04..2026-10-04, so one day is missing.
  Need to confirm its `GM_V` = `SALE_VAL - NET_MAP` before using it. Missing day: **2026-09-19**.
- **Stock validated** against a SQL Server output row (MATNR 1512033694, DB01, 2026-09-04..10-04):
  all 31 days match (STK_Q 3, STK_V 57,378.72). In Snowflake MATNR is 18-char with leading zeros
  (`000000001512033694`), so `TRY_TO_NUMBER(MATNR)` gives the same key as SQL Server.
- Sales not validated yet (that sample row had no sales). Need a SQL Server row that has sales.

## Files

```
sql_server_original/   the three procedures as they are today (reference only)
snowflake/
  00_create_trend_kpi_data.sql              one-time: staging table
  01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql loader procedure
  02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql pivot procedure
  03_daily_tasks.sql                        daily schedule (Snowflake Tasks)
  04_checks.sql                             is it running / is the data right
  05_USP_MRST_SAL_STK_L30_TREND.sql         step 3: report procedure (inputs + joins, incl. broader menu)
  06_USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT.sql  step 2b: MAJ_CAT x STORE_CODE rollup table
```

Run order for setup: 00 → 01 → 02 → test with `CALL` → 06 → 05 → 03.

## MAJ_CAT (2026-10-13)

`PROCESS_DATA_SALE_STK_L30_DAYS` now has `MAJ_CAT` (3rd column, from `GOLD.DIM_PRODUCT_V2`; 'NA'
when missing/blank). Step 2b sums it into `V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT`
(one row per MAJ_CAT + STORE_CODE, same 155 columns), run daily by task `TREND_L30_MAJ_CAT` after step 2.
Report procedure 05 excludes the new column, so callers passing a bare `MAJ_CAT` still work.
Other reports reading the article table with `SELECT *` or a bare `MAJ_CAT` in a join must be checked.

## Open items

- [x] Stock source: `V2RETAIL.BRONZE.ET_STOCK_DATA` covers both SQL Server stock tables (loader updated; double-count issue is gone).
- [x] Sales source mapped: `V2RETAIL.SILVER.V_VBRP` (PRSDT / FKIMG / NETWR / NETWR-WAVWR). Loader updated.
- [x] `V_VBRP` columns confirmed (MATNR / WERKS / PRSDT / FKIMG / NETWR / WAVWR). **All are VARCHAR.** `PRSDT::DATE` read `'YYYYMMDD'` as seconds since 1970, so no sales were loaded. Loader fixed (2026-10-06): explicit `TRY_TO_DATE(PRSDT,'YYYYMMDD')`, `TRY_TO_NUMBER(x,38,4)`, `TRIM`.
- [x] Sales source switched to `V2RETAIL.BRONZE.VBRP`, date `FKDAT_ANA`, filter `FKART_ANA = 'FP'` (user, 2026-10-06).
- [ ] Confirm `BRONZE.VBRP` has MATNR / WERKS / FKIMG / NETWR / WAVWR under those names. Only billing type FP is read: check that SQL Server's sales also exclude returns/cancellations (other billing types).
- [ ] Re-create and re-run Step 1 + 2, then run the `VBRP conversion` check in `04_checks.sql` (expect zero bad values) and re-check HH16.
- [ ] Check cancellations/returns in `V_VBRP` are negative or excluded, and whether `NETWR` matches SQL Server's SALE_VAL (with/without tax). Validate against a SQL Server row that has sales.
- [x] Steps 1 and 2 created and run in `V2RETAIL.SILVER` (2026-10-06). Output matches the Snowflake source data.
- [ ] **Sales lower in Snowflake than SQL Server (parked; re-check after the VARCHAR fix, the gap may have been the date conversion).** Pipeline output matches `V_VBRP`, so the gap is between sources: `VIEW_ET_SALES_DATA` has more sales than `V_VBRP`. Next: compare daily totals / store counts on both sides and get `sp_helptext 'VIEW_ET_SALES_DATA'` to see what SQL Server reads (POS data? other tables? filters?). Must be resolved before reports switch over.
- [ ] Step 3: `DESC TABLE V2RETAIL.GOLD.DIM_PRODUCT_V2` to confirm report columns, then create `05_` and test.
- [x] Broader menu merged into `USP_MRST_SAL_STK_L30_TREND` (2026-10-09, user decision; no separate `_BROADER` procedure, drop it if created). LEFT JOIN alias `D` to `V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA`. Checked 2026-10-07: 456,224 rows, one per MATNR, all numeric (no double counting). Columns MATNR, M_BUYING_TYPE, M_YARN, M_YARN_02 also exist in DIM_PRODUCT_V2, so callers must prefix them (`D.M_YARN` or `B.M_YARN`).
- [x] Location: **`V2RETAIL.SILVER`** for TREND_KPI_DATA, PROCESS_DATA_SALE_STK_L30_DAYS, procedures and tasks. All scripts now use full names. (Warehouse name in tasks still a placeholder.)
- [ ] Decide the daily run time (after source data lands).
- [ ] Find reports/consumers that reference `_GM` columns by name; they must use `_SALE_GM` now.
- [ ] **Column names change daily** (`2026-09-04_STK_Q` disappears tomorrow). Check how the existing reports handle this; consider fixed names (`D01_STK_Q` = yesterday … `D31_STK_Q`).
- [ ] **MATNR is numeric** (leading zeros removed). Report joins to tables with text MATNR need `TRY_TO_NUMBER(x.MATNR) = p.MATNR`.
- [ ] **Step 3: report procedure** (`USP_MRST_SAL_STK_L30_TREND`, drafted in `05_...`). Joins now point to `V2RETAIL.GOLD.DIM_PRODUCT_V2` and `V2RETAIL.GOLD.STORE_PLANT_MASTER`; confirm DIM_PRODUCT_V2 has the same columns as SQL Server's DIM_PRODUCT. Need the list of parameter combinations each report uses so we can test them all.
- [ ] Get the EXECUTE TASK privilege from the Snowflake admin.

## Differences from SQL Server version

- No indexes (Snowflake doesn't use them).
- `CREATE OR REPLACE TABLE` instead of `DROP` + `SELECT INTO`, so the table is swapped in one step.
- Pivot built with `SUM(IFF(...))` instead of `PIVOT` (cleaner column names).
- Empty days are `0` instead of NULL in `PROCESS_DATA_SALE_STK_L30_DAYS` (and so in the MAJ_CAT table) (user decision 2026-10-13).
- Scheduling via Snowflake Tasks instead of SQL Agent.
- `VBRP` columns are VARCHAR: values that can't be converted become NULL (left out) instead of failing the load. `04_checks.sql` counts them.
- `TREND_KPI_DATA` and `PROCESS_DATA_SALE_STK_L30_DAYS` are TRANSIENT with 0-day retention (no paid copies of daily-rebuilt data).
- Stock read from one history table (`ET_STOCK_DATA`) instead of `ET_STOCK_DATA_LOG` UNION `ET_STOCK_DATA`.
- Sales read from `BRONZE.VBRP` (billing type FP, date FKDAT_ANA) instead of `VIEW_ET_SALES_DATA` (SALE_GM = `NETWR - WAVWR` instead of `SALE_VAL - NET_MAP`).
- Metric `GM` renamed to `SALE_GM`: final columns are `<date>_SALE_GM` instead of `<date>_GM`. Reports that refer to `_GM` columns by name must be changed.
- "Today" taken in India time (`CONVERT_TIMEZONE('Asia/Kolkata', ...)`) in steps 1 and 2, because Snowflake's `CURRENT_DATE()` follows the session timezone.
- Step 3: `[x]` brackets converted to `"x"` in both CAT_COLUMNS and CAT_COLUMNS_ALIAS; VAR-ART / M-VND-CD checks ignore case, like SQL Server's collation.

## Store master (2026-10-07)

Report procedure (05_) now joins `V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER` instead of
`V2RETAIL.GOLD.STORE_PLANT_MASTER`, with `ST_STAT = 'ACT' AND ST_TYP = 'STORE'`.
GOLD.STORE_PLANT_MASTER was missing 71 codes (44 of them selling, ~₹30 Cr in 31 days) and marked
53 selling stores as UPC. With the AKS_SILVER table: 430 ACT + 22 UPC stores; no store with sales
in the window is dropped. Only 8 small codes (no sales) are not in it: HN24, RK01, DD01, DU01-03, HB33, STD1.
Only ACT stores are kept, same as SQL Server (user decision 2026-10-07). UPC stores are left out, incl. HW55 which already sells.

Report procedure (05_) is `EXECUTE AS CALLER` (2026-10-07): the owner role `PROGRAMMER_DEV_ROLE`
has no access to `AKS_SILVER.SLV_MIS_STORE_MASTER`, so it runs with the caller's role. Callers need
read access to that table, `GOLD.DIM_PRODUCT_V2`, `BRONZE.ET_ART_BROADER_MENU_DATA` and `SILVER.PROCESS_DATA_SALE_STK_L30_DAYS`.
Alternative: admin grants SELECT on the store master to `PROGRAMMER_DEV_ROLE` and the clause can go.
