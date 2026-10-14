-- One procedure for every L30 trend report: pick the columns, filters and metrics by name.
--
--   CALL V2RETAIL.SILVER.USP_TREND_REPORT(
--       'SEG, DIV, SUB_DIV, ZONE, STORE_CODE, MAJ_CAT, COLOR',   -- group by (names from TREND_DIMENSIONS)
--       '{"ZONE": ["NORTH"], "NOT SEG": ["APP"]}',               -- filters ('' = none)
--       'SALE_Q, SALE_V',                                        -- metrics ('' = all 5)
--       '',                                                      -- '' = return the result now
--       'VIEW',                                                  -- or name + VIEW / TABLE to save it
--       'ZONE, SALE_V DESC');                                    -- sort ('' = unsorted)
--
-- Group by: names from TREND_DIMENSIONS, in the order wanted. "NAME AS LABEL" renames a column.
--           Every DIM_PRODUCT_V2 and ET_ART_BROADER_MENU_DATA column is there by its own name
--           (broader-menu names also in DIM_PRODUCT_V2 get BM_: BM_M_YARN, BM_M_YARN_02, ...).
--           COLOR / SIZE always come from VW_PRODUCT_MASTER, never from those two.
--           No STORE_CODE = all stores added together (company level). '' = one total row.
-- Filters:  JSON, {"NAME": [values]} keeps those values, {"NOT NAME": [values]} drops them.
--           Any name from TREND_DIMENSIONS works, also ones not in the group by.
-- Metrics:  any of STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM. All 31 days of each.
-- Output:   OUTPUT_NAME '' returns the rows. 'V2RETAIL.SILVER.<name>' + 'VIEW' / 'TABLE' creates it.
--           OBJECT_TYPE 'SQL' returns the generated query instead (to check it).
-- Sort:     "NAME [ASC|DESC]", comma separated, applied in that order. NAME can be
--             - a name (or its AS label) from the group by, e.g. MAJ_CAT
--             - a metric = its 31 days added up, e.g. SALE_V DESC (biggest sellers first)
--             - one day column, e.g. 2026-10-13_SALE_Q
--           ASC is the default. Blanks / NULLs always go last.
-- Always:   active stores only (ST_STAT = 'ACT', ST_TYP = 'STORE'); VAR_ART keeps 13-digit articles.
--
-- Only names in TREND_DIMENSIONS are accepted and filter values are quoted, so no SQL text from
-- the caller ends up in the query. New attribute = one INSERT into TREND_DIMENSIONS
-- (a new column in DIM_PRODUCT_V2 / the broader menu is picked up by re-running this file).

USE ROLE PROGRAMMER_DEV_ROLE;


------------------------------------------------------------------------------
-- 1) The list of names the procedure understands
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE V2RETAIL.SILVER.TREND_DIMENSIONS (
    KEY         VARCHAR,   -- name used in the CALL
    EXPR        VARCHAR,   -- SQL behind it (A = main table, P = product, D = broader menu,
                           --   M = SILVER.VW_PRODUCT_MASTER (colour / size only), C = store)
    LABEL       VARCHAR,   -- default output column name (SQL Server's)
    EXTRA_WHERE VARCHAR,   -- condition added whenever the name is grouped by
    NOTE        VARCHAR
);

INSERT INTO V2RETAIL.SILVER.TREND_DIMENSIONS VALUES
    ('SEG',               'P.SEG',               'SEG',            NULL, NULL),
    ('DIV',               'P.DIV',               'DIV',            NULL, NULL),
    ('SUB_DIV',           'P.SUB_DIV',           'SUB-DIV',        NULL, NULL),
    ('MAJ_CAT',           'P.MAJ_CAT',           'MAJ-CAT',        NULL, NULL),
    ('MC_CODE',           'P.MC_CODE',           'MC-CD',          NULL, NULL),
    ('MRP',               'P.MRP',               'MRP',            NULL, NULL),
    ('RNG_SEG',           'P.REG_SEG',           'RNG-SEG',        NULL, NULL),
    -- Colour and size come only from VW_PRODUCT_MASTER (decided 2026-10-14), never from P or D.
    ('COLOR',             'COALESCE(NULLIF(TRIM(M.NEW_COLOR_CODE), ''''), ''NA'')', 'COLOR', NULL, 'VW_PRODUCT_MASTER.NEW_COLOR_CODE, blank -> NA'),
    ('SIZE',              'COALESCE(NULLIF(TRIM(M.NEW_SIZE_DESC), ''''), ''NA'')',  'SIZE',  NULL, 'VW_PRODUCT_MASTER.NEW_SIZE_DESC, blank -> NA'),
    ('FABRIC',            'P.M_FAB_1',           'FABRIC',         NULL, NULL),
    ('MACRO_MVGR',        'P.MACRO_MVGR',        'MACRO MVGR',     NULL, NULL),
    ('MICRO_MVGR',        'P.MAIN_MVGR',         'MICRO MVGR',     NULL, NULL),
    ('M_FAB_MAIN_MVGR_1', 'COALESCE(NULLIF(TRIM(D.M_FAB_MAIN_MVGR_1), ''''), ''NA'')', 'M_FAB_MAIN_MVGR_1', NULL, 'broader menu, blank -> NA'),
    ('M_VND_CD',          'P.MERGE_VENDOR_CODE', 'M-VND-CD',       NULL, NULL),
    ('GEN_ART',           'P.GEN_ART_NUMBER',    'GEN-ART',        NULL, NULL),
    ('VAR_ART',           'A.MATNR',             'VAR-ART',        'LENGTH(A.MATNR::VARCHAR) = 13', 'SQL Server: VAR-ART reports keep 13-digit articles'),
    ('STORE_CODE',        'A.STORE_CODE',        'STORE_CODE',     NULL, NULL),
    ('ZONE',              'COALESCE(C.ZONE, ''NA'')', 'ZONE',      NULL, NULL),
    ('REG',               'COALESCE(C.REG, ''NA'')',  'REG',       NULL, 'same REG code exists in two zones: use with ZONE');

-- Every other DIM_PRODUCT_V2 column, by its own name (text: blank -> NA).
-- Not its colour / size columns: COLOR and SIZE above come from VW_PRODUCT_MASTER only.
INSERT INTO V2RETAIL.SILVER.TREND_DIMENSIONS
SELECT c.COLUMN_NAME,
       IFF(c.DATA_TYPE = 'TEXT', 'COALESCE(NULLIF(TRIM(P."' || c.COLUMN_NAME || '"), ''''), ''NA'')',
                                 'P."' || c.COLUMN_NAME || '"'),
       c.COLUMN_NAME, NULL, 'DIM_PRODUCT_V2'
FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS c
LEFT JOIN V2RETAIL.SILVER.TREND_DIMENSIONS t ON t.KEY = c.COLUMN_NAME
WHERE c.TABLE_SCHEMA = 'GOLD' AND c.TABLE_NAME = 'DIM_PRODUCT_V2'
  AND c.COLUMN_NAME NOT IN ('COLOR', 'COLOR_NEW', 'SIZE_1', 'SIZE_STD')
  AND t.KEY IS NULL;

-- Every ET_ART_BROADER_MENU_DATA column, by its own name (text: blank -> NA).
-- The ones DIM_PRODUCT_V2 also has (MATNR, M_BUYING_TYPE, M_YARN, M_YARN_02) get a BM_ prefix.
INSERT INTO V2RETAIL.SILVER.TREND_DIMENSIONS
SELECT IFF(t.KEY IS NULL, c.COLUMN_NAME, 'BM_' || c.COLUMN_NAME),
       IFF(c.DATA_TYPE = 'TEXT', 'COALESCE(NULLIF(TRIM(D."' || c.COLUMN_NAME || '"), ''''), ''NA'')',
                                 'D."' || c.COLUMN_NAME || '"'),
       IFF(t.KEY IS NULL, c.COLUMN_NAME, 'BM_' || c.COLUMN_NAME), NULL, 'ET_ART_BROADER_MENU_DATA'
FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS c
LEFT JOIN V2RETAIL.SILVER.TREND_DIMENSIONS t ON t.KEY = c.COLUMN_NAME
WHERE c.TABLE_SCHEMA = 'BRONZE' AND c.TABLE_NAME = 'ET_ART_BROADER_MENU_DATA'
  AND NOT (t.KEY IS NOT NULL AND t.NOTE ILIKE 'broader menu%');   -- M_FAB_MAIN_MVGR_1 is already above


------------------------------------------------------------------------------
-- 2) The procedure
------------------------------------------------------------------------------
-- The 5-argument version (before SORT_BY) must go, or 5-argument CALLs would match both.
DROP PROCEDURE IF EXISTS V2RETAIL.SILVER.USP_TREND_REPORT(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE V2RETAIL.SILVER.USP_TREND_REPORT(
    DIMENSIONS  VARCHAR,
    FILTERS     VARCHAR DEFAULT '',
    METRICS     VARCHAR DEFAULT '',
    OUTPUT_NAME VARCHAR DEFAULT '',
    OBJECT_TYPE VARCHAR DEFAULT 'VIEW',
    SORT_BY     VARCHAR DEFAULT ''
)
RETURNS TABLE()
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    n_bad_key    INTEGER;
    n_bad_label  INTEGER;
    n_bad_filter INTEGER;
    n_bad_metric INTEGER;
    n_bad_sort   INTEGER;
    sel          VARCHAR;
    dims         VARCHAR;   -- 'KEY=LABEL|KEY=LABEL' of the group by, for SORT_BY
    order_by     VARCHAR;
    extra_where  VARCHAR;
    filter_where VARCHAR;
    cols         VARCHAR;
    m            VARCHAR DEFAULT UPPER(REPLACE(COALESCE(METRICS, ''), ' ', ''));
    obj_type     VARCHAR DEFAULT UPPER(TRIM(COALESCE(OBJECT_TYPE, 'VIEW')));
    out_name     VARCHAR DEFAULT UPPER(TRIM(COALESCE(OUTPUT_NAME, '')));
    whr          VARCHAR;
    q            VARCHAR;
    res          RESULTSET;
    bad_dimension EXCEPTION (-20101, 'Unknown name in DIMENSIONS: see SELECT * FROM V2RETAIL.SILVER.TREND_DIMENSIONS.');
    bad_label     EXCEPTION (-20102, 'A label after AS may only use letters, digits, space, _ and - (max 60).');
    bad_filter    EXCEPTION (-20103, 'Unknown name in FILTERS (use {"NAME": [..]} or {"NOT NAME": [..]} with names from TREND_DIMENSIONS).');
    bad_metric    EXCEPTION (-20104, 'METRICS may only contain STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM.');
    bad_output    EXCEPTION (-20105, 'OUTPUT_NAME must be V2RETAIL.SILVER.<name> (not a pipeline table) and OBJECT_TYPE VIEW, TABLE or SQL.');
    bad_sort      EXCEPTION (-20106, 'SORT_BY: each item must be a name in the group by, a metric (STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM) or a day column, optionally followed by ASC or DESC.');
BEGIN
    -- Group-by columns: "KEY" or "KEY AS LABEL", looked up in TREND_DIMENSIONS
    SELECT COUNT_IF(d.KEY IS NULL),
           COUNT_IF(p.LBL IS NOT NULL AND NOT REGEXP_LIKE(p.LBL, '[A-Z0-9 _-]{1,60}')),
           LISTAGG(d.EXPR || ' AS "' || COALESCE(p.LBL, d.LABEL) || '"', ', ') WITHIN GROUP (ORDER BY p.IDX),
           LISTAGG(DISTINCT d.EXTRA_WHERE, ' AND '),
           LISTAGG(p.K || '=' || COALESCE(p.LBL, d.LABEL), '|') WITHIN GROUP (ORDER BY p.IDX)
    INTO :n_bad_key, :n_bad_label, :sel, :extra_where, :dims
    FROM (SELECT INDEX AS IDX,
                 UPPER(SPLIT_PART(TRIM(VALUE::STRING), ' ', 1)) AS K,
                 IFF(REGEXP_LIKE(TRIM(VALUE::STRING), '\\S+\\s+AS\\s+.+', 'is'),
                     UPPER(TRIM(REGEXP_REPLACE(TRIM(VALUE::STRING), '^\\S+\\s+AS\\s+', '', 1, 1, 'i'), ' "')),
                     NULL) AS LBL
          FROM TABLE(FLATTEN(INPUT => SPLIT(COALESCE(:DIMENSIONS, ''), ',')))
          WHERE TRIM(VALUE::STRING) <> '') p
    LEFT JOIN V2RETAIL.SILVER.TREND_DIMENSIONS d ON d.KEY = p.K;

    IF (n_bad_key > 0) THEN RAISE bad_dimension; END IF;
    IF (n_bad_label > 0) THEN RAISE bad_label; END IF;

    -- Filters: {"KEY": [values]} -> expr IN (...), {"NOT KEY": [values]} -> expr NOT IN (...)
    -- Values are quoted here (backslash and quote escaped), never pasted in as SQL.
    SELECT COUNT_IF(d.KEY IS NULL),
           LISTAGG(d.EXPR || IFF(x.NEG, ' NOT IN (', ' IN (') || x.VALS || ')', ' AND ')
    INTO :n_bad_filter, :filter_where
    FROM (SELECT REGEXP_LIKE(TRIM(f.KEY), 'NOT\\s+.+', 'i') AS NEG,
                 UPPER(TRIM(REGEXP_REPLACE(TRIM(f.KEY), '^NOT\\s+', '', 1, 1, 'i'))) AS K,
                 LISTAGG('''' || REPLACE(REPLACE(v.VALUE::STRING, '\\', '\\\\'), '''', '''''') || '''', ', ') AS VALS
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(COALESCE(NULLIF(TRIM(:FILTERS), ''), '{}')))) f,
               LATERAL FLATTEN(INPUT => IFF(IS_ARRAY(f.VALUE), f.VALUE, ARRAY_CONSTRUCT(f.VALUE))) v
          GROUP BY 1, 2) x
    LEFT JOIN V2RETAIL.SILVER.TREND_DIMENSIONS d ON d.KEY = x.K;

    IF (n_bad_filter > 0) THEN RAISE bad_filter; END IF;

    -- Metrics -> today's day columns: SUM(A."2026-10-13_SALE_V") AS "2026-10-13_SALE_V", ...
    SELECT COUNT_IF(VALUE::STRING NOT IN ('STK_Q', 'STK_V', 'SALE_Q', 'SALE_V', 'SALE_GM'))
    INTO :n_bad_metric
    FROM TABLE(FLATTEN(INPUT => SPLIT(:m, ',')))
    WHERE VALUE::STRING <> '';

    IF (n_bad_metric > 0) THEN RAISE bad_metric; END IF;

    SELECT LISTAGG('SUM(A."' || COLUMN_NAME || '") AS "' || COLUMN_NAME || '"', ', ')
           WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO :cols
    FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'SILVER'
      AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
      AND REGEXP_LIKE(COLUMN_NAME, '\\d{4}-\\d{2}-\\d{2}_.+')
      AND (:m = '' OR ARRAY_CONTAINS(REGEXP_SUBSTR(COLUMN_NAME, '_(.+)$', 1, 1, 'e', 1)::VARIANT, SPLIT(:m, ',')));

    -- Sort: each item -> group-by label, a metric's 31 days added up, or one day column.
    -- Only names found here end up in the query, never the caller's text.
    SELECT COUNT_IF(o IS NULL),
           LISTAGG(o || ' ' || dir || ' NULLS LAST', ', ') WITHIN GROUP (ORDER BY idx)
    INTO :n_bad_sort, :order_by
    FROM (SELECT x.IDX AS idx, x.DIR AS dir,
                 COALESCE(MAX('"' || g.L || '"'), MAX(t.E), MAX('COALESCE(SUM(A."' || c.COLUMN_NAME || '"), 0)')) AS o
          FROM (SELECT INDEX AS IDX,
                       UPPER(TRIM(REGEXP_REPLACE(TRIM(VALUE::STRING), '\\s+(ASC|DESC)$', '', 1, 1, 'i'), ' "')) AS K,
                       IFF(REGEXP_LIKE(TRIM(VALUE::STRING), '.*\\sDESC', 'is'), 'DESC', 'ASC') AS DIR
                FROM TABLE(FLATTEN(INPUT => SPLIT(COALESCE(:SORT_BY, ''), ',')))
                WHERE TRIM(VALUE::STRING) <> '') x
          LEFT JOIN (SELECT SPLIT_PART(VALUE::STRING, '=', 1) AS K, SPLIT_PART(VALUE::STRING, '=', 2) AS L
                     FROM TABLE(FLATTEN(INPUT => SPLIT(COALESCE(:dims, ''), '|')))) g
                 ON x.K IN (g.K, g.L)
          LEFT JOIN (SELECT REGEXP_SUBSTR(COLUMN_NAME, '_(.+)$', 1, 1, 'e', 1) AS MET,
                            '(' || LISTAGG('COALESCE(SUM(A."' || COLUMN_NAME || '"), 0)', ' + ')
                                   WITHIN GROUP (ORDER BY ORDINAL_POSITION) || ')' AS E
                     FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
                     WHERE TABLE_SCHEMA = 'SILVER'
                       AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
                       AND REGEXP_LIKE(COLUMN_NAME, '\\d{4}-\\d{2}-\\d{2}_.+')
                     GROUP BY 1) t
                 ON t.MET = x.K
          LEFT JOIN (SELECT COLUMN_NAME
                     FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS
                     WHERE TABLE_SCHEMA = 'SILVER'
                       AND TABLE_NAME   = 'PROCESS_DATA_SALE_STK_L30_DAYS'
                       AND REGEXP_LIKE(COLUMN_NAME, '\\d{4}-\\d{2}-\\d{2}_.+')) c
                 ON c.COLUMN_NAME = x.K
          GROUP BY x.IDX, x.DIR);

    IF (n_bad_sort > 0) THEN RAISE bad_sort; END IF;

    -- The query (same joins as USP_BUILD_L30_OUTPUT: each source cut to one row per key first)
    whr := 'C.ST_STAT = ''ACT'' AND C.ST_TYP = ''STORE'''
           || IFF(extra_where IS NULL OR extra_where = '', '', ' AND ' || extra_where)
           || IFF(filter_where IS NULL OR filter_where = '', '', ' AND ' || filter_where);

    q := 'SELECT ' || IFF(sel IS NULL OR sel = '', '', sel || ', ') || cols || '
         FROM (SELECT * EXCLUDE (SEG, DIV, SUB_DIV, MAJ_CAT) FROM V2RETAIL.SILVER.PROCESS_DATA_SALE_STK_L30_DAYS) A
         LEFT JOIN (SELECT * FROM V2RETAIL.GOLD.DIM_PRODUCT_V2
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(MATNR) ORDER BY MAJ_CAT) = 1) P
                ON A.MATNR = TRY_TO_NUMBER(P.MATNR)'
         -- All three are matched on MATNR. The broader menu only holds 10-digit generic MATNRs
         -- (checked 2026-10-14: 590,059 of 619,218 articles match on the first 10 digits, 5,217 on
         -- the full MATNR), so it is matched on the generic part. VW_PRODUCT_MASTER calls MATNR
         -- ARTICLE_NUMBER.
         -- broader menu only when a chosen name needs it (it is the slowest join)
         || IFF(REGEXP_INSTR(COALESCE(sel, '') || ' ' || whr, '(^|[^A-Za-z0-9_])D\\.') > 0, '
         LEFT JOIN (SELECT * FROM V2RETAIL.BRONZE.ET_ART_BROADER_MENU_DATA
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRY_TO_NUMBER(MATNR) ORDER BY MATNR) = 1) D
                ON TRY_TO_NUMBER(LEFT(A.MATNR::VARCHAR, 10)) = TRY_TO_NUMBER(D.MATNR)', '')
         -- product master view only for COLOR / SIZE; only those two columns are read
         || IFF(REGEXP_INSTR(COALESCE(sel, '') || ' ' || whr, '(^|[^A-Za-z0-9_])M\\.') > 0, '
         LEFT JOIN (SELECT TRY_TO_NUMBER(ARTICLE_NUMBER) AS MATNR, NEW_COLOR_CODE, NEW_SIZE_DESC
                    FROM V2RETAIL.SILVER.VW_PRODUCT_MASTER
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY MATNR ORDER BY NEW_COLOR_CODE) = 1) M
                ON A.MATNR = M.MATNR', '') || '
         LEFT JOIN V2RETAIL.AKS_SILVER.SLV_MIS_STORE_MASTER C
                ON A.STORE_CODE = C.ST_CD
         WHERE ' || whr || '
         GROUP BY ALL'
         || IFF(order_by IS NULL OR order_by = '', '', '
         ORDER BY ' || order_by);

    -- Return the rows, the query text, or save as a view / table
    IF (out_name = '' AND obj_type <> 'SQL') THEN
        res := (EXECUTE IMMEDIATE :q);
        RETURN TABLE(res);
    END IF;

    IF (obj_type = 'SQL') THEN
        res := (SELECT :q AS GENERATED_SQL);
        RETURN TABLE(res);
    END IF;

    IF (obj_type NOT IN ('VIEW', 'TABLE')
        OR NOT REGEXP_LIKE(out_name, 'V2RETAIL\\.SILVER\\.[A-Z0-9_]+')
        OR out_name ILIKE ANY ('%PROCESS_DATA_SALE_STK_L30_DAYS%', '%TREND_KPI_DATA%', '%TREND_DIMENSIONS%')) THEN
        RAISE bad_output;
    END IF;

    EXECUTE IMMEDIATE 'CREATE OR REPLACE ' || IFF(obj_type = 'VIEW', 'VIEW ', 'TRANSIENT TABLE ')
                      || out_name || ' COPY GRANTS AS ' || q;

    res := (SELECT :out_name || ' (' || :obj_type || ') created' AS STATUS);
    RETURN TABLE(res);
END;
$$;


------------------------------------------------------------------------------
-- 3) Examples
------------------------------------------------------------------------------
-- Ad hoc, returns rows:
-- CALL V2RETAIL.SILVER.USP_TREND_REPORT('ZONE, MAJ_CAT, COLOR', '{"SEG": ["APP"]}', 'SALE_Q, SALE_V');
-- CALL V2RETAIL.SILVER.USP_TREND_REPORT('MAJ_CAT', '{"STORE_CODE": ["HB05", "DB01"]}');
-- CALL V2RETAIL.SILVER.USP_TREND_REPORT('', '', 'SALE_V');                    -- one total row
-- CALL V2RETAIL.SILVER.USP_TREND_REPORT('SEG, MAJ_CAT', '', '', '', 'SQL');   -- show the query
-- Sorted: biggest-selling MAJ_CAT first within each zone
-- CALL V2RETAIL.SILVER.USP_TREND_REPORT('ZONE, MAJ_CAT', '', 'SALE_Q, SALE_V', '', 'VIEW', 'ZONE, SALE_V DESC');

-- The SQL Server reports, as names:
--   V_MRST_TREND_MJ           'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT'
--   V_MRST_TREND_GEN_ART_CLR  'SEG, DIV, SUB_DIV AS SUB_DIV, MAJ_CAT AS MAJ_CAT, MC_CODE AS MC_CODE, ZONE, REG, STORE_CODE, GEN_ART, COLOR AS CLR'
--   V_MRST_TREND_MJ_CLR_NOT_APP  'SEG, DIV, SUB_DIV, STORE_CODE, MAJ_CAT, COLOR' + '{"NOT SEG": ["APP"]}'
--   MRDC (all stores) = the same without STORE_CODE, e.g. 'SEG, DIV, SUB_DIV, MAJ_CAT, MC_CODE, VAR_ART AS VAR_ART'

-- See what can be used:
-- SELECT KEY, LABEL, NOTE FROM V2RETAIL.SILVER.TREND_DIMENSIONS ORDER BY KEY;
