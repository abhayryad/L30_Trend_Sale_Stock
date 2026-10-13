-- One-time setup: staging table filled daily by USP_GENERATE_L30D_STK_SALE_VQ_MRST.
-- Long format: one row per article x store x date x metric.
-- PARTICULARS_NAME values: STK_Q, STK_V, SALE_Q, SALE_V, SALE_GM
--
-- Lives in V2RETAIL.SILVER (decided 2026-10-06).
-- TRANSIENT + 0-day retention: the table is emptied and refilled daily and can always be
-- rebuilt from source, so we don't pay to keep old copies (Time Travel / Fail-safe).

CREATE TRANSIENT TABLE IF NOT EXISTS V2RETAIL.SILVER.TREND_KPI_DATA (
    MATNR             NUMBER(38,0),
    STORE_CODE        VARCHAR,
    DATES             DATE,
    PARTICULARS_NAME  VARCHAR,
    PARTICULARS_VALUE NUMBER(38,4)
)
DATA_RETENTION_TIME_IN_DAYS = 0;
