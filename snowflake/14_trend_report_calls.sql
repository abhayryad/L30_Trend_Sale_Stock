-- The SQL Server L30 reports as USP_TREND_REPORT calls (needs 13_USP_TREND_REPORT.sql deployed).
-- Same reports as USP_BUILD_TREND_REPORTS_DAILY (11_), numbered the same way.
--
-- Arguments: group by, filters, metrics, output name, object type, sort.
--   '' as output name = rows come back straight away (run one CALL at a time in Snowsight).
--   To save one instead: 'V2RETAIL.SILVER.<name>', 'VIEW' (or 'TABLE').
-- Active stores only, always. COLOR / SIZE come from VW_PRODUCT_MASTER.
-- Sort used here: the hierarchy in order, then biggest 31-day sales value first.

USE ROLE PROGRAMMER_DEV_ROLE;


-- 1. SEG, DIV, SUB_DIV, STORE_CODE, MC_CODE
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MC_CODE', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 2. SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 3. ..., MAJ_CAT, FABRIC (M_FAB_1)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, FABRIC', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 4. ..., MAJ_CAT, MACRO_MVGR
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MACRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 5. ..., MAJ_CAT, MICRO_MVGR (MAIN_MVGR)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MICRO_MVGR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 6. ..., MAJ_CAT, RNG_SEG
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, RNG_SEG');

-- 7. ..., MAJ_CAT, SIZE (from VW_PRODUCT_MASTER.NEW_SIZE_DESC)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SIZE', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');

-- 8. ..., MAJ_CAT, M_FAB_MAIN_MVGR_1 (broader menu)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, M_FAB_MAIN_MVGR_1', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 9. ..., MAJ_CAT, COLOR (from VW_PRODUCT_MASTER.NEW_COLOR_CODE).
--    SQL Server ran it once per DIV: here that is a filter, e.g. '{"DIV": ["MENS"]}'.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');

-- 10. ..., ZONE, STORE_CODE, MAJ_CAT, MRP. SQL Server ran it once per ZONE: here one zone shown.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, MRP', '{"ZONE": ["NORTH"]}', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP');

-- 11. ..., MAJ_CAT, MRP, RNG_SEG
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG', '', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, MRP, RNG_SEG');

-- 12. MRST_ST_GEN_ART_CLR. SQL Server names without hyphen, CLR for colour.
--     SQL Server ran it once per REG; the same REG code is in two zones, so filter both.
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, ZONE, REG, STORE_CODE, GEN_ART, COLOR AS CLR',
    '{"ZONE": ["NORTH"], "REG": ["R10"]}', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, STORE_CODE, SALE_V DESC');

-- 13. MRST_ST_MAJ_M_VND_CD. Vendor reports keep APP / GM / MKT only (SQL Server rule).
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, MAJ_CAT AS MAJ_CAT, M_VND_CD',
    '{"ZONE": ["NORTH"], "SEG": ["APP", "GM", "MKT"]}', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_V DESC');

-- 14. MRST_ST_M_VND_CD
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV AS SUB_DIV, ZONE, STORE_CODE, M_VND_CD',
    '{"ZONE": ["NORTH"], "SEG": ["APP", "GM", "MKT"]}', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- 15. MRST_TREND_ST_MJ_CLR_NOT_APP: report 9 without the APP segment (GM + MKT)
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR', '{"NOT SEG": ["APP"]}', '', '', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, SALE_Q DESC');


------------------------------------------------------------------------------
-- Variations
------------------------------------------------------------------------------
-- MRDC (all stores added together) = leave STORE_CODE out:
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, VAR_ART', '{"SEG": ["APP"]}', 'STK_Q, SALE_Q', '', 'VIEW',
    'SEG, DIV, SUB_DIV, MAJ_CAT, SALE_Q DESC');

-- Top-selling colours per MAJ_CAT in one zone, sales metrics only:
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'ZONE, MAJ_CAT, COLOR', '{"ZONE": ["EAST"], "SEG": ["APP"]}', 'SALE_Q, SALE_V', '', 'VIEW',
    'MAJ_CAT, SALE_V DESC');

-- Any DIM_PRODUCT_V2 / broader-menu column works by its own name:
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'MAJ_CAT, SSN, M_FIT, M_NECK_TYPE, SIZE', '{"SEG": ["APP"]}', 'SALE_Q', '', 'VIEW',
    'MAJ_CAT, SALE_Q DESC');

-- Save a report as a view instead of returning rows (report 2 here):
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT', '', '',
    'V2RETAIL.SILVER.V_TREND_MJ', 'VIEW',
    'SEG, DIV, SUB_DIV, STORE_CODE, SALE_V DESC');

-- See the query a call would run, without running it:
CALL V2RETAIL.SILVER.USP_TREND_REPORT(
    'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR', '', '', '', 'SQL', 'SALE_V DESC');
