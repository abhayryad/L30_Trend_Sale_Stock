# Prompt: Migrate the L30D Sale & Stock pipeline from SQL Server to Snowflake

## Role and context

You are helping a data engineer who is **new to Snowflake** move a daily reporting pipeline from
SQL Server (database `DataV2`) to Snowflake (account `OZ95041`, database `V2RETAIL`).
Explain every step in plain language, and say *why* a Snowflake construct differs from SQL Server.

Project folder: `C:\Users\V51661\Desktop\l30d_sale_stk_snowflake`
- `sql_server_original/` — the three SQL Server procedures as they run today (reference only, do not edit)
- `snowflake/` — the Snowflake versions being written
- `README.md` — status and **open items list; keep it current** after every change

**Do not run queries against Snowflake until the user says they are ready.** Write code and checks
first; the user decides when to execute.

## What the pipeline does

It produces, every day, the last 31 days (yesterday−30 … yesterday) of stock and sales per
article (`MATNR`) per store (`STORE_CODE`), and serves many reports from it.

```
ET_STOCK_DATA ─┐
VBRP          ─┴─► Step 1 loader ─► TREND_KPI_DATA ─► Step 2 pivot ─► PROCESS_DATA_SALE_STK_L30_DAYS ─► Step 3 report proc ─► reports
                                    (long format)                     (wide, 155 cols)                  (+ DIM_PRODUCT_V2, STORE_PLANT_MASTER)
```

### Step 1 — Loader: `USP_GENERATE_L30D_STK_SALE_VQ_MRST` (daily)
Truncates and refills `TREND_KPI_DATA` (MATNR, STORE_CODE, DATES, PARTICULARS_NAME, PARTICULARS_VALUE)
with one row per article × store × date × metric:

| Metric | Source | Logic |
|---|---|---|
| `STK_Q` | stock | `SUM(LABST)`, LGORT IN ('0001','0006') |
| `STK_V` | stock | `SUM(LABST_DMBTR)`, same filter |
| `SALE_Q` | sales | sum of sale quantity |
| `SALE_V` | sales | sum of sale value |
| `GM` | sales | `SUM(SALE_VAL − NET_MAP)` (sale value minus cost) |

MATNR is converted to a number (`TRY_TO_NUMBER`) so leading zeros disappear; dates are cast to DATE.

### Step 2 — Pivot: `USP_PROCESS_DATA_SALE_STK_L30_DAYS` (daily, after Step 1)
Rebuilds `PROCESS_DATA_SALE_STK_L30_DAYS`: one row per MATNR + STORE_CODE, plus 31 days × 5 metrics
= 155 columns named `"<YYYY-MM-DD>_<METRIC>"` (e.g. `"2026-09-04_STK_Q"`), in date order then
STK_Q, STK_V, SALE_Q, SALE_V, GM. **Column names shift by one day every day.**

### Step 3 — Reports: `USP_MRST_SAL_STK_L30_TREND` (on demand)
Inputs:
- `CAT_COLUMNS` — group-by columns, comma separated, e.g. `'STORE_CODE,MAJ_CAT'`
- `CAT_COLUMNS_ALIAS` — select list for them, may rename, e.g. `'store_code as STORE_CODE,MAJ_CAT'`
  (SQL Server callers use `[name]` brackets, e.g. `'MERGE_VENDOR_CODE AS [M-VND-CD]'`)
- `STORE_CODES` — optional comma-separated store filter (`''` = all)

Logic: read the 155 value column names from INFORMATION_SCHEMA, build
`COALESCE(SUM(col),0) AS col` for each, join the wide table to the product dimension
(`A.MATNR = B.ARTICLE_NUMBER`) and store master (`ST_STAT='ACT' AND ST_TYP='STORE'`),
apply the store filter, group by `CAT_COLUMNS`, return the result set.
Special rules:
- alias contains `VAR-ART` → only articles whose number is 13 digits long
- alias = `MERGE_VENDOR_CODE AS [M-VND-CD]` → only `B.SEG IN ('APP','GM','MKT')`

One procedure serves many reports through different parameter combinations.

## Snowflake source tables (confirmed by the user)

| Purpose | SQL Server | Snowflake |
|---|---|---|
| Stock | `ET_STOCK_DATA` (staging) → moved into `ET_STOCK_DATA_LOG` (history) | `V2RETAIL.BRONZE.ET_STOCK_DATA` — **one table for both**; holds daily history. Columns MATNR (18-char, leading zeros), WERKS, LGORT, LABST, LABST_DMBTR, STOCK_DATE (timestamp) |
| Sales | `VIEW_ET_SALES_DATA` (view) | `V2RETAIL.BRONZE.VBRP` (SAP billing items) |
| Product dimension | `DIM_PRODUCT` | `V2RETAIL.GOLD.DIM_PRODUCT_V2` |
| Store master | `STORE_PLANT_MASTER` | `V2RETAIL.GOLD.STORE_PLANT_MASTER` |

Stock has already been validated: MATNR 1512033694, store DB01, 2026-09-04 … 2026-10-04 matched
SQL Server on all 31 days.

## Current state of the Snowflake code

| File | Status |
|---|---|
| `00_create_trend_kpi_data.sql` | done (staging table DDL) |
| `01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql` | stock part done (reads only `V2RETAIL.BRONZE.ET_STOCK_DATA`, no UNION); **sales part uses placeholder `SALES_SOURCE`** |
| `02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql` | done (`SUM(IFF(...))` pivot via dynamic SQL, `CREATE OR REPLACE TABLE`) |
| `03_daily_tasks.sql` | done (Snowflake Tasks: Step 1 then Step 2) |
| `04_checks.sql` | done (task history / data checks) |
| `05_USP_MRST_SAL_STK_L30_TREND.sql` | done, joins point to GOLD tables; `RETURNS TABLE()`, `EXECUTE IMMEDIATE ... USING` for store codes, converts `[ ]` to `" "` in the alias string |

## Open items (in priority order)

1. **VBRP field mapping — the user will provide it. Do not guess column names.** Needed: sale date
   (may require joining header table VBRK for the billing date), quantity, value (with or without tax),
   cost for `NET_MAP`, and how cancellations / returns are treated. Then replace `SALES_SOURCE` in Step 1.
2. **Location for our own objects:** database, schema and warehouse for `TREND_KPI_DATA`,
   `PROCESS_DATA_SALE_STK_L30_DAYS` and the three procedures (scripts currently use unqualified names).
3. **Verify `DIM_PRODUCT_V2`** has the columns the reports use (`ARTICLE_NUMBER`, `SEG`, `MAJ_CAT`,
   `MERGE_VENDOR_CODE`, …) and how `ARTICLE_NUMBER` is stored (the join uses `TRY_TO_NUMBER` to be safe).
4. **Collect every report's parameter combination** and compare each Step 3 output with SQL Server.
5. **Validate sales** against a SQL Server output row that actually has sales.
6. Decide the daily run time (after source data lands); get `EXECUTE TASK` privilege from the admin.
7. Downstream joins: the final table's MATNR is numeric; text MATNR joins need `TRY_TO_NUMBER`.
   Consider whether reports would be better served by fixed column names (`D01_STK_Q` … `D31_STK_Q`).

## Working rules

- Keep behaviour identical to SQL Server unless a difference is deliberate; list every deliberate
  difference in the file header and the README.
- Prefer set-based SQL over loops; Snowflake has no indexes, temp-table `#` syntax, `NOLOCK`, or `ISNULL`.
- Use `CREATE OR REPLACE` so tables swap atomically; never leave reports seeing a half-built table.
- When validating, compare a specific MATNR + store + date range between SQL Server and Snowflake and
  report matches/mismatches explicitly.
- After each change, update the README open-items list.
