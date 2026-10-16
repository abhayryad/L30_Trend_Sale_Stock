-- V_MRDC_ARTICLE_HV: V_MRDC_ARTICLE_MAJCAT_PSF_ACH + ARTICLE_HV classification (all stores).
-- Same rule as V_ARTICLE_HV (23_v_article_hv.sql), but against the all-stores MAJ-CAT average.
-- ARTICLE_HV looks at four achievements (article PSF / MAJ-CAT PSF, as a whole-number %):
--   MAJ_CAT_30D_SALE_ACHIEVEMENT, MAJ_CAT_L7D_SALE_ACHIEVEMENT,
--   MAJ_CAT_30D_GP_ACHIEVEMENT,   MAJ_CAT_L7D_GP_ACHIEVEMENT
-- Each is placed in a band:
--   <= 25% 'D' | > 25..50% 'VV' | > 50..90% 'V' | > 90..125% 'N' | > 125..170% 'H' | > 170..200% 'HH' | > 200% 'G'
-- If all four fall in the same band, ARTICLE_HV is that band; otherwise 'NA'.
-- Bands use the same rounded % that the achievement columns show, so e.g. 25.4% counts as 25% -> 'D'.
-- Run 28_v_mrdc_article_majcat_psf_ach.sql first.

CREATE OR REPLACE VIEW V2RETAIL.SILVER.V_MRDC_ARTICLE_HV AS
WITH PCT AS (
    SELECT A.*,
           ROUND(COALESCE(DIV0NULL(SALE_PSF_30D, MAJCAT_SALE_PSF_30D), 0) * 100, 0) AS P_SALE_30D,
           ROUND(COALESCE(DIV0NULL(SALE_PSF_L7D, MAJCAT_SALE_PSF_L7D), 0) * 100, 0) AS P_SALE_L7D,
           ROUND(COALESCE(DIV0NULL(GP_PSF_30D,   MAJCAT_GP_PSF_30D),   0) * 100, 0) AS P_GP_30D,
           ROUND(COALESCE(DIV0NULL(GP_PSF_L7D,   MAJCAT_GP_PSF_L7D),   0) * 100, 0) AS P_GP_L7D
    FROM V2RETAIL.SILVER.V_MRDC_ARTICLE_MAJCAT_PSF_ACH A
),
BAND AS (
    SELECT P.*,
           CASE WHEN P_SALE_30D <= 25 THEN 'D' WHEN P_SALE_30D <= 50 THEN 'VV' WHEN P_SALE_30D <= 90 THEN 'V'
                WHEN P_SALE_30D <= 125 THEN 'N' WHEN P_SALE_30D <= 170 THEN 'H' WHEN P_SALE_30D <= 200 THEN 'HH'
                ELSE 'G' END AS B_SALE_30D,
           CASE WHEN P_SALE_L7D <= 25 THEN 'D' WHEN P_SALE_L7D <= 50 THEN 'VV' WHEN P_SALE_L7D <= 90 THEN 'V'
                WHEN P_SALE_L7D <= 125 THEN 'N' WHEN P_SALE_L7D <= 170 THEN 'H' WHEN P_SALE_L7D <= 200 THEN 'HH'
                ELSE 'G' END AS B_SALE_L7D,
           CASE WHEN P_GP_30D <= 25 THEN 'D' WHEN P_GP_30D <= 50 THEN 'VV' WHEN P_GP_30D <= 90 THEN 'V'
                WHEN P_GP_30D <= 125 THEN 'N' WHEN P_GP_30D <= 170 THEN 'H' WHEN P_GP_30D <= 200 THEN 'HH'
                ELSE 'G' END AS B_GP_30D,
           CASE WHEN P_GP_L7D <= 25 THEN 'D' WHEN P_GP_L7D <= 50 THEN 'VV' WHEN P_GP_L7D <= 90 THEN 'V'
                WHEN P_GP_L7D <= 125 THEN 'N' WHEN P_GP_L7D <= 170 THEN 'H' WHEN P_GP_L7D <= 200 THEN 'HH'
                ELSE 'G' END AS B_GP_L7D
    FROM PCT P
)
SELECT B.* EXCLUDE (P_SALE_30D, P_SALE_L7D, P_GP_30D, P_GP_L7D,
                    B_SALE_30D, B_SALE_L7D, B_GP_30D, B_GP_L7D),
       IFF(B_SALE_30D = B_SALE_L7D AND B_SALE_30D = B_GP_30D AND B_SALE_30D = B_GP_L7D,
           B_SALE_30D, 'NA') AS ARTICLE_HV
FROM BAND B;
