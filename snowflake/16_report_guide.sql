/*==============================================================================
  L30 TREND REPORTS IN SNOWFLAKE: HOW TO CREATE EVERY SQL SERVER REPORT
================================================================================

  What this file is
  -----------------
  A how-to for the L30 trend reports. Each SQL Server report has a section below
  (PART 2: the 15 store-level reports, PART 2B: the 16 MRDC all-stores reports):
  what it shows, how SQL Server made it, and the Snowflake CALL that makes the same report.
  Run ONE statement at a time in Snowsight (put the cursor in it, Ctrl+Enter).
  Do not "Run All": that would run every report below and save every example view.

  In SQL Server every report was:
      EXEC USP_MRST_SAL_STK_L30_TREND '<group by>', '<columns AS [labels]>', '<store codes>'
  (or the _BY_REG_ZONE / _NOT_APP copies of that procedure), then exported to Excel.

  In Snowflake every report is one call to one procedure:
      CALL V2RETAIL.SILVER.USP_TREND_REPORT(<group by>, <filters>, <metrics>, <output>, <type>, <sort>);
  Columns, filters and sort are given BY NAME. You never write SQL, joins or SUM(...) yourself.

  Before you start
  ----------------
  - USP_TREND_REPORT must be deployed (run 13_USP_TREND_REPORT.sql once).
  - The procedure runs with YOUR rights (EXECUTE AS CALLER). Your role needs SELECT on:
        V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS     (main table, rebuilt 07:00 IST daily)
        V2RETAIL.GOLD.DIM_PRODUCT_V2                       (product master)
        V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA           (broader menu, M_* attributes)
        V2RETAIL.SILVER.VW_PRODUCT_MASTER                  (colour and size only)
        V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER           (stores, ZONE, REG)
    and, to save a report, CREATE VIEW / CREATE TABLE on schema V2RETAIL.SILVER.
  - The data always covers the 31 days up to yesterday.

==============================================================================*/

USE ROLE PROGRAMMER_DEV_ROLE;   -- or any role with the grants listed above
USE WAREHOUSE COMPUTE_WH;


/*==============================================================================
  PART 1. THE SIX ARGUMENTS
================================================================================

  #  Argument      What goes in                                         '' (blank) means
  -- ------------  ---------------------------------------------------  ------------------------
  1  GROUP BY      Names, comma separated, in output column order.      One total row
                   'NAME AS LABEL' renames a column.
                   = SQL Server's 1st + 2nd argument together.
  2  FILTERS       JSON. {"ZONE": ["NORTH"]} keeps those values,         No filter
                   {"NOT SEG": ["APP"]} drops them. Several keys = AND.
                   Any name works, also one not in the group by.
                   = SQL Server's 3rd argument (store codes) and the
                   _BY_REG_ZONE split filter.
  3  METRICS       Any of STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM.        All 5 (155 columns)
                   Each gives all 31 days of that number.
  4  OUTPUT NAME   'V2RETAIL.SILVER.<name>' to save the report.          Show the rows now
  5  TYPE          VIEW  = saved query, recalculated when opened         Must be filled: use 'VIEW'
                   TABLE = saved result, fast to open, frozen at that day
                   SQL   = only show the query it would run
  6  SORT          'NAME [ASC|DESC]', comma separated. NAME is a        Unsorted
                   group-by name or label, a metric (= its 31 days added
                   up, e.g. SALE_V DESC = best sellers first) or one day
                   column ('2026-10-13_SALE_Q'). Blanks go last.

  To give argument 6, arguments 2-5 must be written out (use '' for blanks).

  Always applied, you cannot switch it off:
  - Active stores only: SLV_MIS_STORE_MASTER ST_STAT = 'ACT' AND ST_TYP = 'STORE'
    (same as SQL Server's STORE_PLANT_MASTER filter).
  - Only SEG APP, GM, MKT are in the main table (FAB, ACC, NT ... are left out at step 2).
  - Grouping by VAR_ART keeps 13-digit articles only (SQL Server rule).


  The output: 155 day columns
  ---------------------------
  For every chosen metric there is one column per day, named <YYYY-MM-DD>_<METRIC>:
      "2026-09-14_STK_Q", "2026-09-14_STK_V", ..., "2026-10-14_SALE_GM"
  STK_Q / STK_V   stock quantity / value at end of day (LGORT 0001 + 0006)
  SALE_Q / SALE_V sale quantity / value (billing type FP)
  SALE_GM         gross margin = NETWR - WAVWR. In SQL Server this metric was called GM:
                  Excel sheets that look for "_GM" columns must look for "_SALE_GM".
  The dates move every day, so never hard-code a date column name in Excel / Power BI.
  Empty days are 0, not NULL (SQL Server gave NULL).


  Names you can group or filter by
  --------------------------------
  The names the SQL Server reports used, with the column label each one gets:

  Name                Output label         Comes from                              SQL Server column
  ------------------  -------------------  --------------------------------------  -----------------------
  SEG                 SEG                  DIM_PRODUCT_V2.SEG                      SEG
  DIV                 DIV                  DIM_PRODUCT_V2.DIV                      DIV
  SUB_DIV             SUB-DIV              DIM_PRODUCT_V2.SUB_DIV                  SUB_DIV AS [SUB-DIV]
  MAJ_CAT             MAJ-CAT              DIM_PRODUCT_V2.MAJ_CAT                  MAJ_CAT AS [MAJ-CAT]
  MC_CODE             MC-CD                DIM_PRODUCT_V2.MC_CODE                  MC_CODE AS [MC-CD]
  MRP                 MRP                  DIM_PRODUCT_V2.MRP                      MRP
  RNG_SEG             RNG-SEG              DIM_PRODUCT_V2.REG_SEG                  REG_SEG AS [RNG-SEG]
  FABRIC              FABRIC               DIM_PRODUCT_V2.M_FAB_1                  M_FAB_1 AS FABRIC
  MACRO_MVGR          MACRO MVGR           DIM_PRODUCT_V2.MACRO_MVGR               MACRO_MVGR AS [MACRO MVGR]
  MICRO_MVGR          MICRO MVGR           DIM_PRODUCT_V2.MAIN_MVGR                MAIN_MVGR AS [MICRO MVGR]
  M_VND_CD            M-VND-CD             DIM_PRODUCT_V2.MERGE_VENDOR_CODE        MERGE_VENDOR_CODE AS [M-VND-CD]
  GEN_ART             GEN-ART              DIM_PRODUCT_V2.GEN_ART_NUMBER           GEN_ART_NUMBER AS [GEN-ART]
  VAR_ART             VAR-ART              main table MATNR (13-digit only)        MATNR AS [VAR-ART]
  COLOR               COLOR                VW_PRODUCT_MASTER.NEW_COLOR_CODE        COLOR
  SIZE                SIZE                 VW_PRODUCT_MASTER.NEW_SIZE_DESC         SIZE_1 AS SIZE
  M_FAB_MAIN_MVGR_1   M_FAB_MAIN_MVGR_1    broader menu (blank -> 'NA')            new in Snowflake
  STORE_CODE          STORE_CODE           main table                              STORE_CODE
  ZONE                ZONE                 SLV_MIS_STORE_MASTER.ZONE               C.ZONE (split filter)
  REG                 REG                  SLV_MIS_STORE_MASTER.REG                C.REG  (split filter)

  Plus every other DIM_PRODUCT_V2 column (SSN, FIT, VENDOR_NAME, ARTICLE_STATUS, ...) and every
  broader-menu column (M_FIT, M_NECK_TYPE, M_PATTERN, ...) by its own name. Full list:
      SELECT KEY, LABEL, NOTE FROM V2RETAIL.SILVER.TREND_DIMENSIONS ORDER BY NOTE, KEY;

  Values on 2026-10-15, for filters:
      ZONE  EAST, NORTH
      REG   R1 .. R16. Every REG code exists in BOTH zones (EAST R10 and NORTH R10 are different
            regions), so always filter REG together with ZONE.
      SEG   APP, GM, MKT
      DIV   APP: MENS, LADIES, KIDS
            GM:  FW, TA, SSNL, ST, LS, HF, MA, TG, HH, GM_W, SF, CLN, SCRAP, COVID-19
            MKT: MKT_GIFT, FA_MKT

  Reading a saved report: labels with '-' or a space need double quotes, exactly as written:
      SELECT * FROM V2RETAIL.SILVER.<name> WHERE "MAJ-CAT" = '...' ;
==============================================================================*/


/*==============================================================================
  PART 2. THE 15 SQL SERVER REPORTS
================================================================================
  Each report below has:
    SQL Server  how it was made (EXEC of USP_MRST_SAL_STK_L30_TREND or one of its copies)
    Shows       what one row is
    Columns     output columns before the 155 day columns
    A           the CALL that shows the rows now (all stores, sorted as the export was used)
    B           the same report saved as a view (only needed if Excel / Power BI reads it)
  The SQL Server lines are rebuilt from the report list (11_ / 12_), not copied from the SQL Agent
  jobs: argument order and names are right, spacing and exact filter text may differ.
  Row counts are from 2026-10-15, to give an idea of size. Big reports (over ~1 million rows) are
  better filtered (by ZONE / DIV, like SQL Server's split exports) or saved as a TABLE.
==============================================================================*/


-- -----------------------------------------------------------------------------
-- REPORT 1. STORE x MC CODE                                 (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MC_CODE',
--                  'SEG,DIV,SUB_DIV AS [SUB-DIV],STORE_CODE,MC_CODE AS [MC-CD]', ''
-- Shows       one row per store and MC code
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MC-CD

-- 1A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MC_CODE',      -- group by (labels SUB-DIV and MC-CD are automatic)
    '',                                            -- no filter: all active stores
    '',                                            -- all 5 metrics
    '',                                            -- show the rows now
    'VIEW',                                        -- (ignored when nothing is saved, but must be filled)
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC'); -- hierarchy, then best-selling MC first

-- 1B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MC_CODE', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MC', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 2. STORE x MAJ_CAT                                 (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT',
--                  'SEG,DIV,SUB_DIV AS [SUB-DIV],STORE_CODE,MAJ_CAT AS [MAJ-CAT]', ''
-- Shows       one row per store and major category (~184k rows)
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT
-- Checked     2026-10-15: identical, row by row, to the old daily view V_MRST_TREND_MJ.

-- 2A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 2B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 3. STORE x MAJ_CAT x FABRIC                        (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,M_FAB_1',
--                  '...,MAJ_CAT AS [MAJ-CAT],M_FAB_1 AS FABRIC', ''
-- Shows       one row per store, major category and fabric (DIM_PRODUCT_V2.M_FAB_1)
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, FABRIC

-- 3A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, FABRIC', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 3B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, FABRIC', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_FAB', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 4. STORE x MAJ_CAT x MACRO MVGR                    (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MACRO_MVGR',
--                  '...,MAJ_CAT AS [MAJ-CAT],MACRO_MVGR AS [MACRO MVGR]', ''
-- Shows       one row per store, major category and macro merchandise group
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, MACRO MVGR

-- 4A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MACRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 4B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MACRO_MVGR', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_MACRO_MVGR', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 5. STORE x MAJ_CAT x MICRO MVGR                    (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MAIN_MVGR',
--                  '...,MAJ_CAT AS [MAJ-CAT],MAIN_MVGR AS [MICRO MVGR]', ''
-- Shows       one row per store, major category and micro merchandise group (MAIN_MVGR)
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, MICRO MVGR

-- 5A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MICRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 5B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MICRO_MVGR', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_MICRO_MVGR', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 6. STORE x MAJ_CAT x RANGE SEGMENT                 (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,REG_SEG',
--                  '...,MAJ_CAT AS [MAJ-CAT],REG_SEG AS [RNG-SEG]', ''
-- Shows       one row per store, major category and range segment
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, RNG-SEG
-- Note        the name is RNG_SEG (the column behind it is DIM_PRODUCT_V2.REG_SEG)

-- 6A. show now (sorted by range, as the range order matters more than sales here)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG');

-- 6B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_RNG_SEG', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG');


-- -----------------------------------------------------------------------------
-- REPORT 7. STORE x MAJ_CAT x SIZE                          (SQL Server: USP_MRST_SAL_STK_L30_TREND)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,SIZE_1',
--                  '...,MAJ_CAT AS [MAJ-CAT],SIZE_1 AS SIZE', ''
-- Shows       one row per store, major category and size
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, SIZE
-- Different   SIZE comes from VW_PRODUCT_MASTER.NEW_SIZE_DESC (decided 2026-10-14), not from
--             DIM_PRODUCT_V2.SIZE_1 as in SQL Server. Blank size -> 'NA'.

-- 7A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SIZE', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');

-- 7B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SIZE', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_SIZE', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');


-- -----------------------------------------------------------------------------
-- REPORT 8. STORE x MAJ_CAT x M_FAB_MAIN_MVGR_1             (new in Snowflake)
-- -----------------------------------------------------------------------------
-- SQL Server  none (added 2026-10-13)
-- Shows       one row per store, major category and fabric main MVGR from the broader menu
--             (ET_ART_BROADER_MENU_DATA, matched on the 10-digit generic article).
--             Articles without a value show 'NA' (~7% of articles, ~6.6% of sales).
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, M_FAB_MAIN_MVGR_1 (~419k rows)
-- Checked     2026-10-15: identical, row by row, to the old daily view V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1.

-- 8A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, M_FAB_MAIN_MVGR_1', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 8B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, M_FAB_MAIN_MVGR_1', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_M_FAB_MAIN_MVGR_1', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');


/*------------------------------------------------------------------------------
  Reports 9-14 come from USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE.
  That copy of the procedure had a 4th argument, a WHERE filter, and was run once per
  ZONE, REG or DIV value to get one smaller Excel file each. In Snowflake that split is
  argument 2 (FILTERS). Each report shows the full version and the split version.
------------------------------------------------------------------------------*/


-- -----------------------------------------------------------------------------
-- REPORT 9. STORE x MAJ_CAT x COLOUR                        (SQL Server: _BY_REG_ZONE, split by DIV)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,COLOR',
--                  '...,MAJ_CAT AS [MAJ-CAT],COLOR', '', '<DIV filter>'   -- once per DIV
-- Shows       one row per store, major category and colour (~2.04 million rows: filter it)
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, COLOR
-- Different   COLOR comes from VW_PRODUCT_MASTER.NEW_COLOR_CODE (decided 2026-10-14): short codes
--             such as JET_BLK, A_MIX, OFF_WHT, OLV_GRN, NAV_BLU (179 values). SQL Server and the old
--             daily view showed long names (JET BLACK, ASSORTED MIX, ...). Totals are the same.

-- 9A. one DIV, as SQL Server exported it (change MENS to LADIES, KIDS, ...)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR',
    '{"DIV": ["MENS"]}',                            -- the SQL Server split
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');

-- 9B. all DIVs, saved as a view (filter when reading: WHERE DIV = 'MENS')
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');


-- -----------------------------------------------------------------------------
-- REPORT 10. ZONE x STORE x MAJ_CAT x MRP                   (SQL Server: _BY_REG_ZONE, split by ZONE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MRP',
--                  '...,MAJ_CAT AS [MAJ-CAT],MRP', '', '<ZONE filter>'   -- once per ZONE
-- Shows       one row per store, major category and MRP (price point)
-- Columns     SEG, DIV, SUB-DIV, ZONE, STORE_CODE, MAJ-CAT, MRP
-- Note        ZONE is added as a column so one report can hold both zones (one zone per store,
--             so totals do not change). Stores without a zone show 'NA'.

-- 10A. one zone, as SQL Server exported it (NORTH or EAST)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, MRP',
    '{"ZONE": ["NORTH"]}',
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP');

-- 10B. both zones, saved as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, MRP', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP', 'VIEW',
    'SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, MRP');


-- -----------------------------------------------------------------------------
-- REPORT 11. STORE x MAJ_CAT x MRP x RANGE SEGMENT          (SQL Server: _BY_REG_ZONE, not split)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE 'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MRP,REG_SEG',
--                  '...,MAJ_CAT AS [MAJ-CAT],MRP,REG_SEG AS [RNG-SEG]', '', ''   -- not split
-- Shows       one row per store, major category, MRP and range segment
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, MRP, RNG-SEG

-- 11A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG');

-- 11B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG', '', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_MRP_RNG_SEG', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG');


-- -----------------------------------------------------------------------------
-- REPORT 12. STORE x GENERIC ARTICLE x COLOUR               (SQL Server file: MRST_ST_GEN_ART_CLR, split by REG)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,STORE_CODE,GEN_ART_NUMBER,COLOR',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,STORE_CODE,GEN_ART_NUMBER AS [GEN-ART],COLOR AS CLR',
--                  '', '<REG filter>'   -- once per REG
-- Shows       one row per store, generic article and colour. The largest report: always filter it.
-- Columns     SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, ZONE, REG, STORE_CODE, GEN-ART, CLR
-- Note        This export kept the plain names SUB_DIV / MAJ_CAT / MC_CODE (no hyphen), so the
--             call renames them back with AS. Colour label is CLR.
--             REG codes repeat in both zones: SQL Server's REG filter mixed EAST R10 and NORTH R10.
--             Here ZONE + REG are both filtered and both shown, so each region is its own file.

-- 12A. one region (change ZONE / REG; REG alone would mix two regions)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, ZONE, REG, STORE_CODE, GEN_ART, COLOR AS CLR',
    '{"ZONE": ["NORTH"], "REG": ["R10"]}',
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE, SALE_V DESC');

-- 12B. all regions, saved as a TABLE (computed once, faster to open than a view at this size;
--      a TABLE does not refresh: run this again after the 07:00 load to get the new day)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, ZONE, REG, STORE_CODE, GEN_ART, COLOR AS CLR',
    '', '',
    'V2RETAIL.SILVER.T_MRST_TREND_GEN_ART_CLR', 'TABLE',
    'ZONE, REG, SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 13. STORE x MAJ_CAT x MERGED VENDOR                (SQL Server file: MRST_ST_MAJ_M_VND_CD, split by ZONE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE
--                  'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MERGE_VENDOR_CODE',
--                  'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,MERGE_VENDOR_CODE AS [M-VND-CD]',
--                  '', '<ZONE filter>'   -- once per ZONE
-- Shows       one row per store, major category and merged vendor code
-- Columns     SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, M-VND-CD
-- Note        SQL Server limited vendor reports to SEG APP / GM / MKT. The main table only has
--             those three anyway; the SEG filter is kept so the rule is visible.

-- 13A. one zone, as SQL Server exported it
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, MAJ_CAT AS MAJ_CAT, M_VND_CD',
    '{"ZONE": ["NORTH"], "SEG": ["APP", "GM", "MKT"]}',
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 13B. both zones, saved as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, MAJ_CAT AS MAJ_CAT, M_VND_CD',
    '{"SEG": ["APP", "GM", "MKT"]}', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_M_VND_CD', 'VIEW',
    'ZONE, SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 14. STORE x MERGED VENDOR                          (SQL Server file: MRST_ST_M_VND_CD, split by ZONE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_BY_REG_ZONE
--                  'SEG,DIV,SUB_DIV,STORE_CODE,MERGE_VENDOR_CODE',
--                  'SEG,DIV,SUB_DIV,STORE_CODE,MERGE_VENDOR_CODE AS [M-VND-CD]',
--                  '', '<ZONE filter>'   -- once per ZONE
-- Shows       one row per store and merged vendor code (report 13 without MAJ_CAT)
-- Columns     SEG, DIV, SUB_DIV, ZONE, STORE_CODE, M-VND-CD

-- 14A. one zone, as SQL Server exported it
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, M_VND_CD',
    '{"ZONE": ["NORTH"], "SEG": ["APP", "GM", "MKT"]}',
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 14B. both zones, saved as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, M_VND_CD',
    '{"SEG": ["APP", "GM", "MKT"]}', '',
    'V2RETAIL.SILVER.V_MRST_TREND_M_VND_CD', 'VIEW',
    'ZONE, SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- REPORT 15. STORE x MAJ_CAT x COLOUR, WITHOUT APP          (SQL Server file: MRST_TREND_ST_MJ_CLR_NOT_APP)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND_NOT_APP (a copy of the procedure with SEG <> 'APP' built in)
--                  'SEG,DIV,SUB_DIV,STORE_CODE,MAJ_CAT,COLOR', '...,MAJ_CAT AS [MAJ-CAT],COLOR', ''
-- Shows       report 9 for SEG GM and MKT only
-- Columns     SEG, DIV, SUB-DIV, STORE_CODE, MAJ-CAT, COLOR
-- Note        "NOT SEG" drops values instead of keeping them. No separate procedure needed.
--             COLOR is the VW_PRODUCT_MASTER code, as in report 9.

-- 15A. show now
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR',
    '{"NOT SEG": ["APP"]}',
    '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');

-- 15B. save as a view
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR',
    '{"NOT SEG": ["APP"]}', '',
    'V2RETAIL.SILVER.V_MRST_TREND_MJ_CLR_NOT_APP', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');


/*==============================================================================
  PART 2B. THE 16 MRDC REPORTS (ALL STORES ADDED TOGETHER)
================================================================================
  The MRDC exports are the same procedure as the store reports (USP_MRST_SAL_STK_L30_TREND),
  only WITHOUT STORE_CODE in the group by: every active store is added into one company total.
  The SQL Server lines below are copied from the report list given on 2026-10-15
  (reportData -> fileNames). MRDC means stores only, not DC stock: the procedure keeps
  ST_STAT = 'ACT' AND ST_TYP = 'STORE' like every other report.

  Rules SQL Server applied, and how they carry over:
  - Alias contains VAR-ART -> only 13-digit articles (LEN(ARTICLE_NUMBER) = 13).
    Snowflake: the name VAR_ART does the same.
  - Alias is exactly 'MERGE_VENDOR_CODE AS [M-VND-CD]' (only MRDC_M_VND_CD) -> SEG APP / GM / MKT.
    Snowflake: not needed, the main table only holds those three SEGs.
  - Several MRDC exports kept plain names (SUB_DIV, MAJ_CAT, MC_CODE, GEN_ART_NUMBER) instead of
    SUB-DIV / MAJ-CAT / MC-CD. The calls rename them back with AS so the Excel columns match.

  Differences from the SQL Server files:
  - COLOR / SIZE from VW_PRODUCT_MASTER (JET_BLK instead of JET BLACK; NEW_SIZE_DESC instead of
    SIZE_1): MRDC_TREND_MJ_CLR_WISE, MRDC_TREND_MJ_SIZE_WISE, MRDC_GEN_ART_CLR, MRDC_GEN_ART_SIZE.
  - Stock about 4% lower (only SEG APP / GM / MKT), GM columns are named _SALE_GM, empty days are 0.

  Row counts (2026-10-15, approximate) are in each header. The four article-level reports
  (VAR_ARTICLE, GEN_ART, GEN_ART_CLR, GEN_ART_SIZE) are 160k-540k rows x 155 columns: save
  them as a TABLE (see 2B.17) instead of showing them in Snowsight.

  NOT TESTED as CALLs yet (the connection used to write this cannot run CALL). The same names,
  labels and rules are used by the store reports in PART 2.
==============================================================================*/


-- -----------------------------------------------------------------------------
-- 2B.1 MRDC_TREND_MC_WISE                                   (~1,100 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MC_CODE',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MC_CODE AS [MC-CD]'
-- Columns     SEG, DIV, SUB-DIV, MC-CD
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MC_CODE', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.2 MRDC_TREND_MJ_MRP_RNG_SEG_WISE                       (~15,400 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MRP,REG_SEG',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],MRP [MRP], REG_SEG [RNG-SEG]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, MRP, RNG-SEG
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MRP, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MRP, RNG_SEG');


-- -----------------------------------------------------------------------------
-- 2B.3 MRDC_TREND_MJ_WISE                                   (~800 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.4 MRDC_TREND_MJ_CLR_WISE                               (~14,900 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,COLOR',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],COLOR [COLOR]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, COLOR
-- Different   COLOR = VW_PRODUCT_MASTER code (JET_BLK), not DIM_PRODUCT name (JET BLACK)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, COLOR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_Q DESC');


-- -----------------------------------------------------------------------------
-- 2B.5 MRDC_TREND_MJ_MRP_WISE
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MRP',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],MRP [MRP]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, MRP
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MRP', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MRP');


-- -----------------------------------------------------------------------------
-- 2B.6 MRDC_TREND_MJ_FAB_WISE
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,M_FAB_1',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],M_FAB_1 FABRIC'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, FABRIC
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, FABRIC', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.7 MRDC_TREND_MJ_MACRO_MVGR_WISE
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MACRO_MVGR',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],MACRO_MVGR  [MACRO MVGR]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, MACRO MVGR
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MACRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.8 MRDC_TREND_MJ_MICRO_MVGR_WISE
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MAIN_MVGR',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT], MAIN_MVGR  [MICRO MVGR]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, MICRO MVGR
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MICRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.9 MRDC_TREND_MJ_RNG_SEG_WISE
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,REG_SEG',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT], REG_SEG [RNG-SEG]'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, RNG-SEG
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, RNG_SEG');


-- -----------------------------------------------------------------------------
-- 2B.10 MRDC_TREND_MJ_SIZE_WISE                             (~3,500 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,SIZE_1',
--                  'SEG AS SEG,DIV AS DIV,SUB_DIV AS [SUB-DIV],MAJ_CAT [MAJ-CAT],SIZE_1 AS SIZE'
-- Columns     SEG, DIV, SUB-DIV, MAJ-CAT, SIZE
-- Different   SIZE = VW_PRODUCT_MASTER.NEW_SIZE_DESC, not DIM_PRODUCT.SIZE_1
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, SIZE', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_Q DESC');


-- -----------------------------------------------------------------------------
-- 2B.11 MRDC_M_VND_CD                                       (~1,800 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'MERGE_VENDOR_CODE','MERGE_VENDOR_CODE AS [M-VND-CD]',''
--             (this exact alias made SQL Server add SEG IN ('APP','GM','MKT'))
-- Columns     M-VND-CD
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'M_VND_CD', '', '', '', 'VIEW',
    'SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.12 MRDC_VAR_ARTICLE                                    (~543,000 rows: save as TABLE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,ARTICLE_NUMBER',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,ARTICLE_NUMBER AS [VAR-ART]',''
--             (VAR-ART in the alias made SQL Server keep 13-digit articles only)
-- Columns     SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, VAR-ART
-- Note        VAR_ART is the article number of the main table (= DIM_PRODUCT ARTICLE_NUMBER),
--             13-digit only. Plain labels SUB_DIV / MAJ_CAT / MC_CODE, as in the SQL Server file.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, VAR_ART',
    '', '',
    'V2RETAIL.SILVER.T_MRDC_VAR_ARTICLE', 'TABLE',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.13 MRDC_GEN_ART                                        (~160,000 rows: save as TABLE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER AS GEN_ART_NUMBER',''
-- Columns     SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, GEN_ART_NUMBER
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, GEN_ART AS GEN_ART_NUMBER',
    '', '',
    'V2RETAIL.SILVER.T_MRDC_GEN_ART', 'TABLE',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.14 MRDC_GEN_ART_CLR                                    (~206,000 rows: save as TABLE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER,COLOR',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER AS GEN_ART_NUMBER,COLOR AS [COLOR]',''
-- Columns     SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, GEN_ART_NUMBER, COLOR
-- Different   COLOR = VW_PRODUCT_MASTER code (JET_BLK), not DIM_PRODUCT name (JET BLACK)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, GEN_ART AS GEN_ART_NUMBER, COLOR',
    '', '',
    'V2RETAIL.SILVER.T_MRDC_GEN_ART_CLR', 'TABLE',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.15 MRDC_GEN_ART_SIZE                                   (~424,000 rows: save as TABLE)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER,SIZE_1',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT,MC_CODE,GEN_ART_NUMBER AS GEN_ART_NUMBER,SIZE_1 AS [SIZE]',''
-- Columns     SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, GEN_ART_NUMBER, SIZE
-- Different   SIZE = VW_PRODUCT_MASTER.NEW_SIZE_DESC, not DIM_PRODUCT.SIZE_1
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, GEN_ART AS GEN_ART_NUMBER, SIZE',
    '', '',
    'V2RETAIL.SILVER.T_MRDC_GEN_ART_SIZE', 'TABLE',
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.16 MRDC_MAJ_CAT_M_VND_CD                               (~11,300 rows)
-- -----------------------------------------------------------------------------
-- SQL Server  EXEC USP_MRST_SAL_STK_L30_TREND 'SEG,DIV,SUB_DIV,MAJ_CAT,MERGE_VENDOR_CODE',
--                  'SEG,DIV,SUB_DIV,MAJ_CAT AS [MAJ-CAT],MERGE_VENDOR_CODE AS [M-VND-CD]',''
-- Columns     SEG, DIV, SUB_DIV, MAJ-CAT, M-VND-CD   (SUB_DIV plain, MAJ-CAT with hyphen, as in SQL Server)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT, M_VND_CD', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_V DESC');


-- -----------------------------------------------------------------------------
-- 2B.17 Saving any MRDC report
-- -----------------------------------------------------------------------------
-- Any call above can be saved: put a name in argument 4 and TABLE (or VIEW) in argument 5,
-- e.g. MRDC_TREND_MJ_WISE as a table for Excel:
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT', '', '',
    'V2RETAIL.SILVER.T_MRDC_TREND_MJ_WISE', 'TABLE',
    'SEG, DIV, SUB_DIV, SALE_V DESC');
-- A TABLE stays on the day it was made: run the CALL again after the 07:00 IST load.
-- Read it:   SELECT * FROM V2RETAIL.SILVER.T_MRDC_TREND_MJ_WISE;
-- Check it:  its SUM("<day>_SALE_V") equals the active-store total in 4.5 below.


/*==============================================================================
  PART 3. VARIATIONS THE SQL SERVER PROCEDURE ALSO ALLOWED
==============================================================================*/

-- 3.1 Some stores only (SQL Server's 3rd argument, e.g. 'HB05,DB01')
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT',
    '{"STORE_CODE": ["HB05", "DB01"]}',
    '', '', 'VIEW',
    'STORE_CODE, SALE_V DESC');

-- 3.2 Company level: leave STORE_CODE out and all active stores are added together.
--     The 16 MRDC reports in PART 2B are built this way.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, SALE_V DESC');

-- 3.3 Variant articles (VAR-ART): 13-digit articles only, as in SQL Server.
--     Many rows: keep the filter and pick only the metrics you need.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, VAR_ART',
    '{"SEG": ["APP"], "DIV": ["MENS"]}',
    'STK_Q, SALE_Q',                                -- only 2 metrics = 62 day columns
    '', 'VIEW',
    'MAJ_CAT, SALE_Q DESC');

-- 3.4 Fewer columns: only sales, no stock (31 x 2 = 62 day columns instead of 155)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', 'SALE_Q, SALE_V', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 3.5 Sort by one day: yesterday's best sellers first (use a date that is in today's 31 days)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'MAJ_CAT', '', 'SALE_Q', '', 'VIEW',
    '2026-10-14_SALE_Q DESC');

-- 3.6 Any other attribute by its own name (DIM_PRODUCT_V2 or broader menu)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'MAJ_CAT, SSN, M_FIT, M_NECK_TYPE', '{"SEG": ["APP"]}', 'SALE_Q, SALE_V', '', 'VIEW',
    'MAJ_CAT, SALE_V DESC');

-- 3.7 Your own column labels (letters, digits, space, _ and - only)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'ZONE AS AREA, MAJ_CAT AS CATEGORY, COLOR AS SHADE', '{"SEG": ["APP"]}', 'SALE_Q', '', 'VIEW',
    'AREA, SALE_Q DESC');


/*==============================================================================
  PART 4. SAVING, READING AND CHECKING
==============================================================================*/

-- 4.1 VIEW or TABLE?
--     VIEW : always shows today's data, but its 155 column names are fixed when it is created.
--            After the next 07:00 load the main table has new date columns and the view breaks
--            ("invalid identifier"). Re-run its CALL every day after 07:15 IST, or use a TABLE.
--     TABLE: a copy of the result. Opens fast, never breaks, but stays on the day it was made.
--            Re-run the CALL to refresh it. Good for big reports (9, 12) and for Excel exports.
--     Saving needs a name starting with V2RETAIL.SILVER. The pipeline tables
--     (PROCESS_DATA_SALE_STK_L30_DAYS*, TREND_KPI_DATA, TREND_DIMENSIONS) are refused.

-- 4.2 Read a saved report (this one exists after running 2B). Labels with '-' or a space need
--     double quotes.
SELECT *
FROM V2RETAIL.SILVER.V_MRST_TREND_MJ
WHERE STORE_CODE = 'HB05'
  AND DIV = 'MENS'
ORDER BY "2026-10-14_SALE_V" DESC;

-- 4.3 Remove a saved report you no longer need (commented out so it never runs by accident)
-- DROP VIEW  IF EXISTS V2RETAIL.SILVER.V_MRST_TREND_MJ;
-- DROP TABLE IF EXISTS V2RETAIL.SILVER.T_MRST_TREND_GEN_ART_CLR;

-- 4.4 See the query a call would run, without running it (TYPE = 'SQL')
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', 'SALE_V', '', 'SQL');

-- 4.5 Check a report: for any day, its total must equal the main table's total for active stores.
--     (Compare with the matching column of your report, e.g. SUM("2026-10-14_SALE_V").)
SELECT SUM(A."2026-10-14_SALE_V") AS SALE_V_ACTIVE_STORES,
       SUM(A."2026-10-14_STK_V")  AS STK_V_ACTIVE_STORES
FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS A
JOIN V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER C
  ON A.STORE_CODE = C.ST_CD
WHERE C.ST_STAT = 'ACT' AND C.ST_TYP = 'STORE';
--     2026-10-15 run: SALE_V 182,248,009.07 and STK_V 8,830,389,172.73 for 2026-10-14.


/*==============================================================================
  PART 5. ERRORS AND WHAT THEY MEAN
================================================================================
  -20101 Unknown name in DIMENSIONS   a group-by name is not in TREND_DIMENSIONS (check spelling,
                                      e.g. MC_CODE not MC-CD, RNG_SEG not REG_SEG, MICRO_MVGR not MAIN_MVGR)
  -20102 Label ...                    a label after AS has characters other than letters, digits,
                                      space, _ and -, or is longer than 60
  -20103 Unknown name in FILTERS      a filter key is not a known name, or the JSON is wrong
                                      (keys and values in double quotes, values in [ ])
  -20104 METRICS ...                  a metric other than STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM
  -20105 OUTPUT_NAME ...              saving outside V2RETAIL.SILVER, over a pipeline table, or a
                                      TYPE other than VIEW / TABLE / SQL
  -20106 SORT_BY ...                  a sort item that is not a group-by name or label, a metric or
                                      a day column of today's 31 days
  "invalid identifier '"2026-..."'"   a saved VIEW from an earlier day: re-run its CALL (see 4.1)
  "Insufficient privileges"           your role is missing SELECT on one of the five tables at the top
==============================================================================*/
