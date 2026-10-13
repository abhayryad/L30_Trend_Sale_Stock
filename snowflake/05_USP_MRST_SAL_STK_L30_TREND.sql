-- Step 3 (reports): sums the 155 day/metric columns of PROCESS_DATA_SALE_STK_L30_DAYS
-- grouped by whatever descriptive columns the caller asks for (store, major category,
-- vendor, ...). One procedure serves many reports through its 3 inputs:
--
--   CAT_COLUMNS        columns to group by, comma separated      e.g. 'STORE_CODE,MAJ_CAT'
--   CAT_COLUMNS_ALIAS  what to show for them (can rename)        e.g. 'STORE_CODE AS STORE_CODE,MAJ_CAT'
--   STORE_CODES        optional store filter, comma separated    e.g. 'DB01,HB05'  ('' = all stores)
--
-- Example (same as the SQL Server example):
--   CALL V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND('STORE_CODE,MAJ_CAT', 'store_code as STORE_CODE,MAJ_CAT', '');
--
-- Broader menu (merged in 2026-10-09; replaces the separate USP_MRST_SAL_STK_L30_TREND_BROADER):
--   LEFT JOIN to V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA (alias D), matched on the first
--   10 digits of the article, so a 13-digit variant gets its 10-digit generic's attributes.
--   One row per MATNR (checked 2026-10-07), so it adds columns without changing the numbers.
--   MATNR, M_BUYING_TYPE, M_YARN, M_YARN_02 exist in both B and D: callers must prefix them
--   (B.M_YARN or D.M_YARN), otherwise Snowflake raises "ambiguous column name".
--
-- SEG, DIV, SUB_DIV, MAJ_CAT in PROCESS_DATA_SALE_STK_L30_DAYS (added 2026-10-13): left out here
-- (EXCLUDE in the FROM, and not summed) so existing callers passing a bare SEG / DIV / SUB_DIV /
-- MAJ_CAT still get B.<column> instead of an "ambiguous column name" error.
-- Since 2026-10-13 step 2 keeps only SEG APP / GM / MKT, so every report here is limited to those.
--
-- TODO before running:
--   * Joined tables: V2RETAIL.GOLD.DIM_PRODUCT_V2 (was DIM_PRODUCT in SQL Server)
--     and V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER (store master; replaced GOLD.STORE_PLANT_MASTER
--     on 2026-10-07, which was missing 71 store codes incl. 44 selling stores).
--   * Check that DIM_PRODUCT_V2 has the same column names the reports use
--     (ARTICLE_NUMBER, SEG, MAJ_CAT, MERGE_VENDOR_CODE, ...).
--   * Check how DIM_PRODUCT_V2.ARTICLE_NUMBER is stored (number, or text with leading zeros).
--     The join below uses TRY_TO_NUMBER so it works either way.
--
-- Differences from SQL Server:
--   * Square brackets in CAT_COLUMNS and CAT_COLUMNS_ALIAS (e.g. [M-VND-CD]) are turned into
--     Snowflake double quotes automatically, so existing callers can pass the same strings.
--   * Not a behaviour change, but needed for it: the VAR-ART and M-VND-CD checks ignore
--     case and outer spaces (ILIKE / UPPER / TRIM), because SQL Server's default collation
--     compares that way and Snowflake's plain = and LIKE do not.
--   * Column list read in table order (ORDINAL_POSITION) instead of sorting by the date
--     in the name; step 2 already creates them in date order.
--   * The CM_BGT_* exclusion list was dropped: those columns don't exist in this table.
--   * The extra STORE_PLANT_MASTER check on STORE_CODES was dropped: the main query
--     already inner-joins the active store master, so the result is the same.
--   * Store codes are passed as a bind value, not pasted into the SQL text.
--   * Only ACT (active) stores, same as SQL Server (user decision 2026-10-07; UPC was
--     briefly included from 2026-10-06).
--   * All objects use full names (V2RETAIL.SILVER...), so the result doesn't depend on the
--     caller's current database/schema.

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_MRST_SAL_STK_L30_TREND(
    CAT_COLUMNS       VARCHAR DEFAULT '',
    CAT_COLUMNS_ALIAS VARCHAR DEFAULT '',
    STORE_CODES       VARCHAR DEFAULT ''
)
RETURNS TABLE()
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    condition      VARCHAR DEFAULT '';
    columns_sum    VARCHAR;
    hierarchy_cols VARCHAR;
    select_cols    VARCHAR;
    sql_text       VARCHAR;
    res            RESULTSET;
BEGIN
    -- Extra filter for two special reports (same rules as SQL Server)
    IF (CAT_COLUMNS_ALIAS ILIKE '%VAR-ART%') THEN
        condition := 'AND LENGTH(TRY_TO_NUMBER(B.ARTICLE_NUMBER)::VARCHAR) = 13';
    ELSEIF (UPPER(TRIM(CAT_COLUMNS_ALIAS)) = 'MERGE_VENDOR_CODE AS [M-VND-CD]') THEN
        condition := 'AND B.SEG IN (''APP'',''GM'',''MKT'')';
    END IF;

    -- COALESCE(SUM("2026-09-04_STK_Q"), 0) AS "2026-09-04_STK_Q", ... for every day/metric column
    SELECT LISTAGG('COALESCE(SUM(A."' || COLUMN_NAME || '"), 0) AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :columns_sum
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND COLUMN_NAME NOT IN ('MATNR', 'STORE_CODE', 'SEG', 'DIV', 'SUB_DIV', 'MAJ_CAT');

    -- GROUP BY list: 'STORE_CODE, MAJ_CAT' -> STORE_CODE, MAJ_CAT (spaces trimmed, [x] -> "x")
    SELECT LISTAGG(REPLACE(REPLACE(TRIM(VALUE), '[', '"'), ']', '"'), ', ') WITHIN GROUP (ORDER BY INDEX)
    INTO :hierarchy_cols
    FROM TABLE(SPLIT_TO_TABLE(:CAT_COLUMNS, ','));

    -- SQL Server [name] -> Snowflake "name"
    select_cols := REPLACE(REPLACE(CAT_COLUMNS_ALIAS, '[', '"'), ']', '"');

    sql_text :=
        'SELECT ' || select_cols || ', ' || columns_sum || '
         FROM (SELECT * EXCLUDE (SEG, DIV, SUB_DIV, MAJ_CAT) FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) A
         INNER JOIN V2RETAIL.GOLD.DIM_PRODUCT_V2 B
                 ON A.MATNR = TRY_TO_NUMBER(B.ARTICLE_NUMBER)
         INNER JOIN V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER C
                 ON A.STORE_CODE = C.ST_CD AND C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE''
         LEFT JOIN V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA D
                 ON TRY_TO_NUMBER(LEFT(A.MATNR::VARCHAR, 10)) = TRY_TO_NUMBER(D.MATNR)
         WHERE (? = '''' OR A.STORE_CODE IN (SELECT TRIM(VALUE) FROM TABLE(SPLIT_TO_TABLE(?, '',''))))
         ' || condition || '
         GROUP BY ' || hierarchy_cols;

    res := (EXECUTE IMMEDIATE :sql_text USING (STORE_CODES, STORE_CODES));
    RETURN TABLE(res);
END;
$$;
