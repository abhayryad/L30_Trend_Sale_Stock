# L30D Sale & Stock: SQL Server → Snowflake

Moving the daily "last 30 days stock + sale" process and its reports from SQL Server (`DataV2`) to Snowflake.
Everything lives in **`V2RETAIL.SILVER`**, is owned by **`PROGRAMMER_DEV_ROLE`**, and refreshes **every day at 07:00 IST**.

## In short

```
07:00  Step 1  collect stock + sales of the last 31 days   → V2RETAIL.SILVER.TREND_KPI_DATA (long list)
  ↓    Step 2  one row per article per store, APP/GM/MKT   → V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS (main table)
  ├──► Step 2b MAJ_CAT summary                              → V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT
  └──► Step 4  re-create the 15 report views                → V2RETAIL.SILVER.V_MRST_TREND_* views
       Step 3  on-demand report procedure (not scheduled)   → V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND
       Step 5  on-demand trend reports by name, with sort   → V2RETAIL.SILVER.USP_TREND_REPORT
```

Each step starts as soon as the previous one succeeds. If a step fails, the ones after it don't run and
yesterday's data stays in place. After the morning run, everything shows the **31 days up to yesterday**.

## Objects created (full names)

All in database `V2RETAIL`, schema `SILVER`, owned by `PROGRAMMER_DEV_ROLE`. Short names used further
down in this README always mean `V2RETAIL.SILVER.<name>`.

| Object | Type | Created by | Purpose |
|---|---|---|---|
| `V2RETAIL.SILVER.TREND_KPI_DATA` | transient table | [00_](snowflake/00_create_trend_kpi_data.sql) | step 1 output (long list) |
| `V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS` | transient table | [02_](snowflake/02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql) (procedure) | main table, step 2 |
| `V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT` | transient table | [06_](snowflake/06_USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT.sql) (procedure) | MAJ_CAT summary, step 2b |
| `V2RETAIL.SILVER.TREND_DIMENSIONS` | table | [13_](snowflake/13_USP_TREND_REPORT.sql) | names usable in `USP_TREND_REPORT` |
| `V2RETAIL.SILVER.V_MRST_TREND_*` (15) | views | `USP_BUILD_TREND_REPORTS_DAILY` | report views, step 4 |
| `V2RETAIL.SILVER.USP_GENERATE_L30D_STK_SALE_VQ_MRST` | procedure | [01_](snowflake/01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql) | step 1 |
| `V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS` | procedure | [02_](snowflake/02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql) | step 2 |
| `V2RETAIL.SILVER.USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT` | procedure | [06_](snowflake/06_USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT.sql) | step 2b |
| `V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND` | procedure | [05_](snowflake/05_USP_MRST_SAL_STK_L30_TREND.sql) | step 3 |
| `V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT` | procedure | [11_](snowflake/11_output_builder.sql) | step 4 view builder |
| `V2RETAIL.SILVER.USP_BUILD_TREND_REPORTS_DAILY` | procedure | [11_](snowflake/11_output_builder.sql) / [12_](snowflake/12_run_mrst_rename.sql) | step 4 report list |
| `V2RETAIL.SILVER.USP_TREND_REPORT` | procedure | [13_](snowflake/13_USP_TREND_REPORT.sql) | step 5 |
| `V2RETAIL.SILVER.TREND_L30_LOAD` | task | [03_](snowflake/03_daily_tasks.sql) | 07:00 IST, runs step 1 |
| `V2RETAIL.SILVER.TREND_L30_PIVOT` | task | [03_](snowflake/03_daily_tasks.sql) | after LOAD, step 2 |
| `V2RETAIL.SILVER.TREND_L30_MAJ_CAT` | task | [03_](snowflake/03_daily_tasks.sql) | after PIVOT, step 2b |
| `V2RETAIL.SILVER.TREND_L30_OUTPUTS` | task | [11_](snowflake/11_output_builder.sql) | after PIVOT, step 4 |

Superseded by 11_ (created by [10_](snowflake/10_report_views.sql); may still exist in Snowflake): `V2RETAIL.SILVER.USP_CREATE_V_L30_SALE_STK_MACRO_MVGR`,
`V2RETAIL.SILVER.V_L30_SALE_STK_MACRO_MVGR`, task `V2RETAIL.SILVER.TREND_L30_VIEWS`.

## The numbers

Every output has 5 numbers for each of the last 31 days (yesterday-30 .. yesterday):

| Metric | Meaning |
|---|---|
| `STK_Q` | Stock quantity (LGORT 0001 + 0006) |
| `STK_V` | Stock value |
| `SALE_Q` | Sale quantity |
| `SALE_V` | Sale value |
| `SALE_GM` | Gross margin = `NETWR - WAVWR` (was `GM` = `SALE_VAL - NET_MAP` in SQL Server) |

Columns are named `<YYYY-MM-DD>_<METRIC>`, e.g. `2026-10-12_SALE_V`: 31 days × 5 = 155 columns.
**The names change every day** (the oldest day drops off, yesterday is added). Anything that reads these
tables or views (Excel, Power BI, SQL) must not hard-code date column names.

## Sources

| Data | Snowflake table | Columns used | Replaces in SQL Server |
|---|---|---|---|
| Stock | `V2RETAIL.BRONZE.ET_STOCK_DATA` (daily history) | MATNR, WERKS, STOCK_DATE, LGORT (`0001` + `0006`), LABST (qty), LABST_DMBTR (value) | `ET_STOCK_DATA_LOG` + `ET_STOCK_DATA` |
| Sales | `V2RETAIL.BRONZE.VBRP`, `FKART_ANA = 'FP'` | MATNR, WERKS, FKDAT_ANA ('YYYYMMDD' text), FKIMG (qty), NETWR (value), NETWR − WAVWR (margin). All VARCHAR, converted explicitly | `VIEW_ET_SALES_DATA` |
| Product | `V2RETAIL.GOLD.DIM_PRODUCT_V2` (alias P) | SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, MACRO_MVGR, MAIN_MVGR, M_FAB_1, REG_SEG, SIZE_1, COLOR_NEW (used as COLOR), MRP, … | `DIM_PRODUCT` |
| Broader menu | `V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA` (alias D) | 88 `M_*` attributes, matched on the 10-digit generic article | same |
| Stores | `V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER` (alias C) | ST_CD, ST_STAT, ST_TYP, ZONE, REG, … | `STORE_PLANT_MASTER` |
| Colour / size (step 5 only) | `V2RETAIL.SILVER.VW_PRODUCT_MASTER` (alias M) | `NEW_COLOR_CODE`, `NEW_SIZE_DESC` only; its `ARTICLE_NUMBER` = MATNR | new |

MATNR is 18 characters with leading zeros in Snowflake; all steps use `TRY_TO_NUMBER(MATNR)`, which gives
the same key as SQL Server.

## Step by step

### Step 1: collect the raw numbers
`USP_GENERATE_L30D_STK_SALE_VQ_MRST` ([01_](snowflake/01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql)) reads stock
and sales for the last 31 days and writes them to `V2RETAIL.SILVER.TREND_KPI_DATA` as a long list: one row per article,
store, day and metric.

### Step 2: one row per article per store (the main table)
`USP_PROCESS_DATA_SALE_STK_L30_DAYS` ([02_](snowflake/02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql)) rebuilds
**`V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS`**:

- Columns: `MATNR, STORE_CODE, SEG, DIV, SUB_DIV, MAJ_CAT` + the 155 day columns.
- SEG / DIV / SUB_DIV / MAJ_CAT come from `DIM_PRODUCT_V2`; blank DIV / SUB_DIV / MAJ_CAT → `'NA'`.
- Empty days are `0`, not NULL (user decision 2026-10-13).
- **Only SEG `APP`, `GM`, `MKT` are kept** (user decision 2026-10-13). Dropped on 2026-10-13: FAB, ACC, NT,
  SERVICE1 and blank SEG = ~35k articles, no sales (3 units), ~₹50 Cr stock value on the last day
  (~4%, mostly NT ₹41 Cr). **Stock totals are therefore ~4% lower than SQL Server's**, which keeps all SEGs.
  Articles missing from `DIM_PRODUCT_V2` are dropped too (none on 2026-10-13).

### Step 2b: MAJ_CAT summary
`USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT` ([06_](snowflake/06_USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT.sql))
rebuilds **`V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT`**: the main table summed per
`SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE` (same 155 columns).

In APP / GM / MKT each MAJ_CAT has exactly one SEG / DIV / SUB_DIV (checked 2026-10-13: 648 APP, 350 GM,
70 MKT MAJ_CATs, none with more than one), so it is one row per MAJ_CAT + store. The 84 MAJ_CATs with
several (e.g. DENIM: DENIM_AW / LW / UW) are all FAB / ACC / NT, which step 2 filters out.

### Step 3: on-demand report procedure
`USP_MRST_SAL_STK_L30_TREND` ([05_](snowflake/05_USP_MRST_SAL_STK_L30_TREND.sql)) is the SQL Server-style
procedure: give it the columns to group by and it returns the result straight away (nothing is saved).

```sql
CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT', 'STORE_CODE AS STORE_CODE,MAJ_CAT', '');
```

- Inputs as in SQL Server: group-by columns, column list with names (`[x]` is turned into `"x"`), store codes (`''` = all).
- Joins product master (B), active stores only (C: `ST_STAT = 'ACT'`, `ST_TYP = 'STORE'`), broader menu (D).
- Leaves the main table's SEG / DIV / SUB_DIV / MAJ_CAT out, so a bare `SEG` or `MAJ_CAT` still means `B.<column>`.
- Special filters kept from SQL Server: VAR-ART reports → 13-digit articles; `MERGE_VENDOR_CODE AS [M-VND-CD]` → SEG APP/GM/MKT.
- `EXECUTE AS CALLER`: callers need read access to the main table, `DIM_PRODUCT_V2`, the broader menu and the store master.

### Step 4: report views (rebuilt every morning)
[11_output_builder.sql](snowflake/11_output_builder.sql). Each report is a view. Views must be re-created
every day because a view remembers the exact column names it was created with, and the date columns
change daily. Nothing has to be truncated: a view holds no data (it reads the main table when opened),
and `CREATE OR REPLACE` swaps the old definition for the new one in one step.

**The builder: `USP_BUILD_L30_OUTPUT(OUTPUT_NAME, OBJECT_TYPE, GROUP_COLS, WHERE_CLAUSE)`**

```sql
CALL V2RETAIL.SILVER.USP_BUILD_L30_OUTPUT(
    'V2RETAIL.SILVER.V_MRST_TREND_MJ',                                 -- what to create
    'VIEW',                                                              -- VIEW, or TABLE (computed once, opens faster)
    'SEG, DIV, SUB_DIV AS "SUB-DIV", STORE_CODE, MAJ_CAT AS "MAJ-CAT"',  -- group by
    'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''');                     -- optional filter ('' = none)
```

What it does:
1. Checks the inputs (VIEW / TABLE only; refuses to overwrite the pipeline tables).
2. Reads today's 155 day columns and writes `SUM(...)` for each.
3. Always LEFT JOINs **P** (product master), **D** (broader menu, first 10 digits of the article) and
   **C** (store master), each cut to one row per key first, so a join can never double the numbers.
4. Adds your columns and filter and `GROUP BY ALL` (groups by every column that isn't a sum, so columns are listed once).
5. `CREATE OR REPLACE VIEW … COPY GRANTS` (keeps the read access people already had).

Rules for `GROUP_COLS`:
- Most names need no prefix. Only these exist in more than one table and need one (checked 2026-10-13):
  `MATNR` (A, P, D) and `M_YARN`, `M_YARN_02`, `M_BUYING_TYPE` (P, D), e.g. `D.M_YARN`.
- `AS` renames; names with `-` or spaces need double quotes: `MAJ_CAT AS "MAJ-CAT"`. Query them the same way: `SELECT "MAJ-CAT" …`.
- Blank values stay NULL unless wrapped: `COALESCE(NULLIF(TRIM(col), ''), 'NA') AS col`
  (inside the CALL string, quotes are doubled: `''''` and `''NA''`).
- `EXECUTE AS CALLER`, so the filter text can't do more than the caller already can.

Tested 2026-10-13 as a SELECT (store × MAJ_CAT × MACRO_MVGR × M_YARN × ZONE, active stores): totals equal
the main table, and joins multiplied no rows.

**The list: `USP_BUILD_TREND_REPORTS_DAILY()`**: one `CALL` per report, run by task `TREND_L30_OUTPUTS`
after step 2. Current reports (all in `V2RETAIL.SILVER`, active stores only, same column names as SQL Server):

| # | View | Group by (output names) | From SQL Server call |
|---|---|---|---|
| 1 | `V_MRST_TREND_MC` | SEG, DIV, SUB-DIV, STORE_CODE, MC-CD | `…'SEG,DIV,SUB_DIV,STORE_CODE,MC_CODE'` |
| 2 | `V_MRST_TREND_MJ` | … STORE_CODE, MAJ-CAT | `…,MAJ_CAT` |
| 3 | `V_MRST_TREND_MJ_FAB` | … MAJ-CAT, FABRIC (M_FAB_1) | `…,MAJ_CAT,M_FAB_1` |
| 4 | `V_MRST_TREND_MJ_MACRO_MVGR` | … MAJ-CAT, MACRO MVGR | `…,MAJ_CAT,MACRO_MVGR` |
| 5 | `V_MRST_TREND_MJ_MICRO_MVGR` | … MAJ-CAT, MICRO MVGR (MAIN_MVGR) | `…,MAJ_CAT,MAIN_MVGR` |
| 6 | `V_MRST_TREND_MJ_RNG_SEG` | … MAJ-CAT, RNG-SEG (REG_SEG) | `…,MAJ_CAT,REG_SEG` |
| 7 | `V_MRST_TREND_MJ_SIZE` | … MAJ-CAT, SIZE (SIZE_1) | `…,MAJ_CAT,SIZE_1` |
| 8 | `V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1` | … MAJ-CAT, M_FAB_MAIN_MVGR_1 (broader menu; blank → 'NA') | new in Snowflake |
| 9 | `V_MRST_TREND_MJ_CLR` | … MAJ-CAT, COLOR (COLOR_NEW) | `_BY_REG_ZONE …,MAJ_CAT,COLOR` |
| 10 | `V_MRST_TREND_MJ_MRP` | … ZONE, STORE_CODE, MAJ-CAT, MRP | `_BY_REG_ZONE …,MAJ_CAT,MRP` |
| 11 | `V_MRST_TREND_MJ_MRP_RNG_SEG` | … MAJ-CAT, MRP, RNG-SEG | `_BY_REG_ZONE …,MAJ_CAT,MRP,REG_SEG` |
| 12 | `V_MRST_TREND_GEN_ART_CLR` | SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, ZONE, REG, STORE_CODE, GEN-ART, CLR | `_BY_REG_ZONE` (MRST_ST_GEN_ART_CLR) |
| 13 | `V_MRST_TREND_MJ_M_VND_CD` | SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, M-VND-CD | `_BY_REG_ZONE` (MRST_ST_MAJ_M_VND_CD) |
| 14 | `V_MRST_TREND_M_VND_CD` | SEG, DIV, SUB_DIV, ZONE, STORE_CODE, M-VND-CD | `_BY_REG_ZONE` (MRST_ST_M_VND_CD) |
| 15 | `V_MRST_TREND_MJ_CLR_NOT_APP` | as 9, SEG GM + MKT only | `_NOT_APP` (MRST_TREND_ST_MJ_CLR_NOT_APP) |

Report 8 comes from the broader menu: on 2026-10-13, 575,397 of 619,077 articles have a value
(10 distinct values, 93.4% of sales); the rest show as `'NA'`.

Reports 9–14 are SQL Server's `_BY_REG_ZONE` reports. SQL Server exports them once per ZONE / REG / DIV;
here each is one view, and the split is a `WHERE` when reading (e.g. `WHERE ZONE = 'NORTH'`).

**Add a report:** add a `CALL` to `USP_BUILD_TREND_REPORTS_DAILY`, re-run its `CREATE`, then run the new
`CALL` once so the view exists today. From the next morning it is rebuilt automatically.

**Read a report:**
```sql
SELECT * FROM V2RETAIL.SILVER.V_MRST_TREND_MJ WHERE STORE_CODE = 'HB05';
```

**Check a report:** its total for a day equals the main table's for active stores (query in section 4 of `11_`).

Limits: a view recalculates every time it is opened (switch a heavy report to `TABLE`); if one report
fails, the ones after it in the list are not rebuilt that day and the task shows as failed.

Step 4 still takes COLOR from `P.COLOR_NEW` and SIZE from `P.SIZE_1`; step 5 takes them from
`VW_PRODUCT_MASTER` (see below), so the two can differ for colour / size reports.

### Step 5: trend reports by name (`USP_TREND_REPORT`)
[13_USP_TREND_REPORT.sql](snowflake/13_USP_TREND_REPORT.sql) (deploy: run the whole file).
One procedure for any L30 report: columns, filters, metrics and sort are given **by name**, never as SQL.
Ready-made calls for all 15 SQL Server reports: [14_trend_report_calls.sql](snowflake/14_trend_report_calls.sql).

```sql
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, MAJ_CAT',        -- 1. GROUP BY  : columns in the output
    '{"ZONE": ["NORTH"]}',      -- 2. FILTERS   : which rows to keep
    'SALE_Q, SALE_V',           -- 3. METRICS   : which number columns
    '',                         -- 4. OUTPUT    : '' = show rows now, or a name to save
    'VIEW',                     -- 5. TYPE      : VIEW / TABLE / SQL
    'MAJ_CAT, SALE_V DESC');    -- 6. SORT      : order of the rows
```

| # | Argument | What goes in | `''` (blank) means |
|---|---|---|---|
| 1 | Group by | Names from `TREND_DIMENSIONS`, in output order. `NAME AS LABEL` renames (letters, digits, space, `_`, `-`) | One total row |
| 2 | Filters | JSON: `{"ZONE": ["NORTH"]}` keeps values, `{"NOT SEG": ["APP"]}` drops them; several keys = AND. Any name works, also one not in the group by | No filter |
| 3 | Metrics | Any of `STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM` (all 31 days of each) | All 5 (155 columns) |
| 4 | Output name | `V2RETAIL.SILVER.<name>` to save | Return the rows now |
| 5 | Type | `VIEW` / `TABLE` (with a name in 4), or `SQL` = return the generated query | Not optional: leave `'VIEW'` |
| 6 | Sort | `NAME [ASC\|DESC]`, comma separated: a group-by name or label, a metric (= its 31 days added up, e.g. `SALE_V DESC` = biggest sellers first), or one day column (`2026-10-13_SALE_Q`). NULLs last | Unsorted |

Arguments 2–6 are optional, but to give a sort, 2–5 must be filled (blanks are fine).
Always: active stores only (`ST_STAT = 'ACT'`, `ST_TYP = 'STORE'`); `VAR_ART` keeps 13-digit articles.

**Names (`V2RETAIL.SILVER.TREND_DIMENSIONS`, 162 on 2026-10-14):**
- 19 report names with SQL Server labels: `SEG, DIV, SUB_DIV (SUB-DIV), MAJ_CAT (MAJ-CAT), MC_CODE (MC-CD), MRP,
  RNG_SEG, COLOR, SIZE, FABRIC (M_FAB_1), MACRO_MVGR, MICRO_MVGR (MAIN_MVGR), M_FAB_MAIN_MVGR_1, M_VND_CD,
  GEN_ART, VAR_ART, STORE_CODE, ZONE, REG`.
- **Every `DIM_PRODUCT_V2` column** by its own name (56), e.g. `SSN, FIT, VENDOR_NAME, ARTICLE_STATUS`,
  **except its colour / size columns** (`COLOR, COLOR_NEW, SIZE_1, SIZE_STD`).
- **Every `ET_ART_BROADER_MENU_DATA` column** by its own name (87), e.g. `M_FIT, M_NECK_TYPE, M_PATTERN`.
  The four also in `DIM_PRODUCT_V2` get a `BM_` prefix: `BM_MATNR, BM_M_BUYING_TYPE, BM_M_YARN, BM_M_YARN_02`.
- Text columns: blank → `'NA'`. The list is built from the two tables' column lists when 13_ is run, so a
  new column is picked up by re-running the file. List them: `SELECT KEY, NOTE FROM V2RETAIL.SILVER.TREND_DIMENSIONS ORDER BY NOTE, KEY;`
- New name by hand = one `INSERT` into `TREND_DIMENSIONS` (key, SQL expression, label, extra WHERE, note).

**COLOR and SIZE come only from `VW_PRODUCT_MASTER`** (user decision 2026-10-14), never from
`DIM_PRODUCT_V2` or the broader menu: `COLOR` = `NEW_COLOR_CODE` (e.g. JET_BLK, A_MIX, OFF_WHT),
`SIZE` = `NEW_SIZE_DESC`; blank → `'NA'` (~0.6% of rows on 2026-10-14).

**Joins, all on MATNR** (each cut to one row per MATNR first, so a join never multiplies numbers):

| Alias | Source | Matched on | Joined when |
|---|---|---|---|
| A | `V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS` | – | always |
| P | `V2RETAIL.GOLD.DIM_PRODUCT_V2` | `MATNR` (= its `ARTICLE_NUMBER` on every row) | always |
| D | `V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA` | first 10 digits of MATNR: it only holds 10-digit generics (590,059 of 619,218 articles match; the full MATNR would match 5,217) | a chosen name needs it |
| M | `V2RETAIL.SILVER.VW_PRODUCT_MASTER` (2 columns only) | `ARTICLE_NUMBER` (= MATNR) | COLOR or SIZE is used |
| C | `V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER` | `STORE_CODE = ST_CD` | always |

Tested 2026-10-14 as plain SELECTs (the connection used could not create objects): with the M join,
14,575,961 rows in = 14,575,961 out; the sort parser accepts names, labels, metrics and day columns and
rejects anything else. The file drops the old 5-argument version of the procedure (before `SORT_BY`),
so existing 5-argument calls still work. A saved VIEW keeps the ORDER BY, but readers should still sort
when they query it; a TABLE is written in sorted order. `EXECUTE AS CALLER`: callers need read access to
the main table, `DIM_PRODUCT_V2`, the broader menu, `VW_PRODUCT_MASTER` and the store master.

## Daily schedule (Snowflake tasks)

| Task | Runs | Calls |
|---|---|---|
| `V2RETAIL.SILVER.TREND_L30_LOAD` | 07:00 IST (`CRON 0 7 * * * Asia/Kolkata`) | step 1 |
| `V2RETAIL.SILVER.TREND_L30_PIVOT` | after LOAD | step 2 |
| `V2RETAIL.SILVER.TREND_L30_MAJ_CAT` | after PIVOT | step 2b |
| `V2RETAIL.SILVER.TREND_L30_OUTPUTS` | after PIVOT | step 4 (`USP_BUILD_TREND_REPORTS_DAILY`) |

- Owner: `PROGRAMMER_DEV_ROLE` (all tasks in a chain need the same owner). Warehouse `COMPUTE_WH`.
- Why 07:00: on 2026-10-09 the sources were last updated at 03:57 IST (VBRP) and 05:02 IST (stock).
- Tasks were renamed on 2026-10-13 from `T_L30D_*`. **First run checked 2026-10-14:** LOAD 07:00–07:01,
  PIVOT 07:01–07:12, MAJ_CAT and OUTPUTS done by 07:12; all 8 views re-created, ending at 2026-10-13, and
  view totals equal the main table for active stores (SALE_V 2026-10-13: 166,434,951).
- Did they run? See [03_daily_tasks.sql](snowflake/03_daily_tasks.sql) (TASK_HISTORY query).
- Change the time: suspend `TREND_L30_LOAD`, `ALTER TASK … SET SCHEDULE`, resume it.
  A task chain can only be changed while its first task is suspended.

## Files

```
sql_server_original/   SQL Server procedures as they were (reference only)
snowflake/
  00_create_trend_kpi_data.sql                      one-time: staging table
  01_USP_GENERATE_L30D_STK_SALE_VQ_MRST.sql         step 1: loader
  02_USP_PROCESS_DATA_SALE_STK_L30_DAYS.sql         step 2: main table (pivot, SEG/DIV/SUB_DIV/MAJ_CAT, APP/GM/MKT filter)
  03_daily_tasks.sql                                daily schedule: LOAD → PIVOT → MAJ_CAT
  04_checks.sql                                     is it running / is the data right
  05_USP_MRST_SAL_STK_L30_TREND.sql                 step 3: on-demand report procedure
  06_USP_PROCESS_DATA_SALE_STK_L30_DAYS_MAJCAT.sql  step 2b: MAJ_CAT summary table
  07_store_compare.sql                              SQL Server vs Snowflake, per store
  08_store_status_compare.sql                       store status: STORE_PLANT_MASTER vs SLV_MIS_STORE_MASTER
  09_maj_cat_store.sql                              ad-hoc MAJ_CAT × store queries (long + wide)
  10_report_views.sql                               superseded by 11_ (first single-view version)
  11_output_builder.sql                             step 4: view builder, report list, task TREND_L30_OUTPUTS
  12_run_mrst_rename.sql                            one-off: report list with V_MRST_TREND_* names + drop old V_L30_* views
  13_USP_TREND_REPORT.sql                           step 5: TREND_DIMENSIONS (names) + USP_TREND_REPORT
  14_trend_report_calls.sql                         step 5: the 15 SQL Server reports as USP_TREND_REPORT calls
```

Setup order: 00 → 01 → 02 → 06 → 05 → 03 → 11 → 13, all as `PROGRAMMER_DEV_ROLE`.
After changing a procedure file, re-run its `CREATE` in Snowflake: editing the file alone changes nothing.

## Differences from SQL Server

- Stock from one history table (`ET_STOCK_DATA`) instead of `ET_STOCK_DATA_LOG` UNION `ET_STOCK_DATA` (no double count).
- Sales from `BRONZE.VBRP` (billing type FP, date FKDAT_ANA) instead of `VIEW_ET_SALES_DATA`.
- Metric `GM` renamed `SALE_GM` (`NETWR - WAVWR`): reports that use `_GM` column names must change.
- Only SEG APP / GM / MKT in the main table (SQL Server keeps all), so stock totals are ~4% lower.
- Empty days are `0` instead of NULL in the main table and everything built from it.
- `CREATE OR REPLACE` instead of `DROP` + `SELECT INTO`: tables and views are swapped in one step, never empty.
- Pivot built with `SUM(IFF(...))` instead of `PIVOT` (cleaner column names). No indexes.
- Snowflake Tasks instead of SQL Agent.
- `TREND_KPI_DATA`, the main table and the MAJ_CAT table are TRANSIENT with 0-day retention (no paid copies of daily-rebuilt data).
- VBRP values that can't be converted become NULL (left out) instead of failing the load; `04_checks.sql` counts them.
- "Today" taken in India time (`CONVERT_TIMEZONE('Asia/Kolkata', ...)`), because `CURRENT_DATE()` follows the session timezone.
- Step 3: `[x]` turned into `"x"`; VAR-ART / M-VND-CD checks ignore case, like SQL Server's collation.
- Reports are views rebuilt daily (step 4) instead of `EXEC` calls; column names kept (`"SUB-DIV"`, `"MAJ-CAT"`, …).
- Store master `AKS_SILVER.SLV_MIS_STORE_MASTER` instead of `STORE_PLANT_MASTER` (see below).

## Decisions and findings

### Store master (2026-10-07)
Reports use `V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER` with `ST_STAT = 'ACT' AND ST_TYP = 'STORE'`, not
`GOLD.STORE_PLANT_MASTER`, which was missing 71 codes (44 selling, ~₹30 Cr in 31 days) and marked 53 selling
stores as UPC. With the AKS_SILVER table: 430 ACT + 22 UPC stores; no store with sales in the window is
dropped. Only 8 small codes (no sales) are not in it: HN24, RK01, DD01, DU01-03, HB33, STD1. Only ACT stores
are kept, same as SQL Server; UPC stores are left out, incl. HW55 which already sells. 632 codes, all unique (2026-10-13).
`PROGRAMMER_DEV_ROLE` has SELECT on it (checked 2026-10-13).

### Broader menu (2026-10-07 / 2026-10-13)
`ET_ART_BROADER_MENU_DATA`: one row per MATNR (no duplicates), 88 columns. Matched on the first 10 digits
of the article, so a 13-digit variant gets its generic's attributes. 589,893 of 619,077 L30 articles (95.3%)
match (2026-10-13). Merged into procedure 05 as alias D (no separate `_BROADER` procedure; drop it if created).

### VW_PRODUCT_MASTER vs DIM_PRODUCT_V2 / broader menu (2026-10-14)
`V2RETAIL.SILVER.VW_PRODUCT_MASTER` (rebuilt 2026-10-14, one row per article, 3,794,131 rows) was
compared with `DIM_PRODUCT_V2` article by article. Decision: **keep `DIM_PRODUCT_V2` and the broader menu;
take only colour and size from the view** (step 5).

- Same in both: article description, article type, creation date, raw colour / size, standardised size,
  vendor design, vendor code / name / city, M_BUYING_TYPE, WEAVE_3, FIT, BODY_STYLE, GEN_ART.
- The view's `M_*` columns are the broader menu's (same 10-digit join), so they are identical to D.
- Differences found (user: not important for now):
  - SEG / DIV / SUB_DIV / MAJ_CAT empty for ~510k articles (587 MC codes missing from `ZMC_MASTER`,
    e.g. B-M_TEES_HS 41k, B-M_JEANS 23k, B-L_KURTI_*); `DIM_PRODUCT_V2` uses `DIM_MERCH_HIERARCHY_CURRENT`.
  - MACRO / MAIN MVGR, M_FAB_1/2, M_YARN, WEAVE_2, M_YARN_02 blank where the broader menu is blank
    (`DIM_PRODUCT_V2` falls back to `ZCT04_CHARACTER`).
  - MERGE_VENDOR_CODE differs for ~258k articles (view's vendor merge doesn't merge).
  - MC_CODE differs for ~24.9k (mostly kids: view has older MC codes, e.g. 131030301 vs 135420101); MC_DESC spellings.
  - GEN_ARTICLE_DESC is the variant's description in the view.
  - Colour: view maps MBQ / SAMPLING / RFD → MULTICOLOR (DIM_PRODUCT_V2 leaves NULL); 172 MRPs only in the view;
    ART_STATUS always NULL in the view.
- Query for the missing categories: join the view to `DIM_PRODUCT_V2` on article number,
  `WHERE V.MAJOR_CATEGORY_DESCRIPTION IS NULL`, group by `P.MAJ_CAT`.

### First checks (2026-10-05)
- `ET_STOCK_DATA` holds daily history (40 days checked). **Stock validated** against a SQL Server row
  (MATNR 1512033694, DB01, 2026-09-04..10-04): all 31 days match (STK_Q 3, STK_V 57,378.72).
- Sales not yet validated against a SQL Server row that has sales.

## Open items

- [ ] **Sales lower in Snowflake than SQL Server (parked).** Pipeline output matches its source, so the gap is between sources. Next: compare daily totals / store counts on both sides and get `sp_helptext 'VIEW_ET_SALES_DATA'`. Must be resolved before reports switch over.
- [ ] Only billing type FP is read from VBRP: check that SQL Server's sales also exclude returns/cancellations, and whether `NETWR` matches SQL Server's SALE_VAL (with/without tax).
- [ ] Run the `VBRP conversion` check in `04_checks.sql` (expect zero bad values).
- [ ] `USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE`: get its SQL Server code (`sp_helptext`) to confirm it only adds ZONE + REG; then enable its 3 reports and handle its STORE_CODE filter.
- [ ] Grant SELECT on the report views to the reader role(s).
- [ ] Run section 3 of `11_` once: drops the old `V_L30_STORE_*` views (renamed `V_MRST_TREND_*` 2026-10-14) and the 3 leftover `V_L30_REGZONE_*` views.
- [ ] Find reports/consumers that use `_GM` column names (now `_SALE_GM`) or hard-code date column names.
- [ ] Other reports reading the main table with `SELECT *`, or a bare SEG / DIV / SUB_DIV / MAJ_CAT in a join, must be checked (new columns since 2026-10-13).
- [ ] MATNR is numeric: joins to tables with text MATNR need `TRY_TO_NUMBER(x.MATNR) = p.MATNR`.
- [ ] Deploy `13_USP_TREND_REPORT.sql` (run the whole file in Snowsight) and try a call from `14_`.
- [ ] Step 4 views (`11_`) still take COLOR / SIZE from `DIM_PRODUCT_V2`: switch to `VW_PRODUCT_MASTER` too?
- [ ] Grant SELECT on `VW_PRODUCT_MASTER` to whoever calls `USP_TREND_REPORT` (it runs as the caller).
- [x] Stock source: `BRONZE.ET_STOCK_DATA` covers both SQL Server stock tables.
- [x] Sales source: `BRONZE.VBRP`, date `FKDAT_ANA`, `FKART_ANA = 'FP'` (2026-10-06); VARCHAR conversion fixed.
- [x] Location `V2RETAIL.SILVER`, owner `PROGRAMMER_DEV_ROLE`, warehouse `COMPUTE_WH`.
- [x] Daily run time 07:00 IST; tasks renamed `TREND_L30_*` and scheduled (2026-10-13).
- [x] Store master switched to `AKS_SILVER.SLV_MIS_STORE_MASTER` (2026-10-07).
- [x] SEG / DIV / SUB_DIV / MAJ_CAT on the main table; APP / GM / MKT filter in step 2 (2026-10-13).
- [x] Column names that change daily: report views are re-created every morning (step 4, 2026-10-13).
- [x] Report list from SQL Server turned into 7 views + 1 new (2026-10-13).
- [x] First automatic run 2026-10-14 07:00: all 4 tasks succeeded, 8 views rebuilt, totals checked.
- [x] `USP_TREND_REPORT`: sorting, all DIM_PRODUCT_V2 + broader-menu columns, colour / size from `VW_PRODUCT_MASTER` (2026-10-14).
- [x] `VW_PRODUCT_MASTER` compared with `DIM_PRODUCT_V2`: not a replacement yet, used for colour / size only (2026-10-14).
