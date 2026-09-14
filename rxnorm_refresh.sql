-- ======================================================
-- RxNorm monthly refresh process
-- This script identifies new RxNorm-to-NDC mappings to add,
-- and active codes to retire from the reference table.
--
-- Assumptions:
--   * ref_id is generated automatically by the target table.
--   * note is optional metadata and is set to NULL by default in this procedure.
-- ======================================================

-- ======================================================
-- STEP 0: define refresh-period parameters
-- Supply refresh_month_start as the first day of the source-data month
-- being processed (for example, 2026-08-01 for the August 2026 files).
-- The value below is a runtime placeholder and should be substituted by
-- the execution environment before the script runs.
-- This view derives the effective dates for the refresh month so the
-- procedure does not rely on the runtime execution date.
-- Business rule: new rows begin on the first day of the refresh month,
-- and eed is treated as an inclusive end date, so retirements are stamped
-- with the last day of the previous month to preserve the prior code as
-- active through that day.
-- ======================================================
CREATE OR REPLACE TEMP VIEW refresh_parameters AS
SELECT
    CAST('${refresh_month_start}' AS DATE) AS refresh_esd,
    date_sub(CAST('${refresh_month_start}' AS DATE), 1) AS retirement_eed;

-- ======================================================
-- STEP 1: create RxNorm temp table from source text files
-- This view produces a curated list of RxNorm drug codes mapped to NDCs.
-- ======================================================
CREATE OR REPLACE TEMP VIEW current_month_rxnorm AS
WITH source_rxnorm AS (
    SELECT
        DISTINCT
        rs.atv AS code,
        rc.str AS description,
        rc.tty
    FROM ca_phm_stg.bronze_ca_phm_ref.rxnsat rs
    JOIN ca_phm_stg.bronze_ca_phm_ref.rxnconso rc
      ON rs.rxcui = rc.rxcui
    WHERE rs.atn = 'NDC'
      AND rc.sab = 'RXNORM'
      AND rc.lat = 'ENG'
      AND rc.ispref = 'Y'
      AND rc.tty IN ('SCD', 'SBD', 'GPCK', 'BPCK')
),
ranked_rxnorm AS (
    SELECT
        code,
        description,
        ROW_NUMBER() OVER (
            PARTITION BY code
            ORDER BY
                CASE tty
                    WHEN 'SCD' THEN 1
                    WHEN 'SBD' THEN 2
                    WHEN 'GPCK' THEN 3
                    WHEN 'BPCK' THEN 4
                    ELSE 5
                END,
                description
        ) AS row_num
    FROM source_rxnorm
)
SELECT
    'RXNORM_DRUG_CODE' AS codesystem,
    code,
    description
FROM ranked_rxnorm
WHERE row_num = 1;

-- ======================================================
-- STEP 2: create temp table for new/append codes
-- This view identifies codes present in the current source data but missing
-- from the existing RxNorm reference table, preparing them for insertion.
-- ======================================================
CREATE OR REPLACE TEMP VIEW current_update AS
SELECT
    'A' AS add_end,
    cm.codesystem,
    cm.code,
    cm.description,
    rp.refresh_esd AS esd,
    NULL AS note
FROM current_month_rxnorm cm
CROSS JOIN refresh_parameters rp
LEFT JOIN ca_phm_stg.caphm_sandbox_reference_drug.rxnorm_drug_code rx
  ON rx.codesystem = cm.codesystem
 AND rx.code = cm.code
 AND rx.eed IS NULL
WHERE rx.code IS NULL;

-- ======================================================
-- STEP 3: append new code additions into rxnorm_drug_code
-- This inserts only the new RxNorm drug codes identified in current_update.
-- ======================================================
INSERT INTO ca_phm_stg.caphm_sandbox_reference_drug.rxnorm_drug_code (
    add_end,
    codesystem,
    code,
    description,
    esd,
    note
)
SELECT
    add_end,
    codesystem,
    code,
    description,
    esd,
    note
FROM current_update;

-- ======================================================
-- STEP 4: identify codes for end dating
-- This view identifies active reference codes that are no longer present
-- in the current month's RxNorm source data.
-- ======================================================
CREATE OR REPLACE TEMP VIEW expired_codes AS
SELECT
    'E' AS add_end,
    rx.codesystem,
    rx.code,
    rx.description,
    rx.esd,
    rx.note
FROM ca_phm_stg.caphm_sandbox_reference_drug.rxnorm_drug_code rx
LEFT JOIN current_month_rxnorm cm
  ON rx.codesystem = cm.codesystem
 AND rx.code = cm.code
WHERE rx.eed IS NULL
  AND rx.codesystem = 'RXNORM_DRUG_CODE'
  AND cm.code IS NULL;

-- ======================================================
-- STEP 5: end-date expired codes in rxnorm_drug_code
-- This updates the existing active rows so they are no longer returned
-- as active once the new refresh month begins.
-- ======================================================
MERGE INTO ca_phm_stg.caphm_sandbox_reference_drug.rxnorm_drug_code rx
USING (
    SELECT
        ec.codesystem,
        ec.code,
        ec.esd,
        rp.retirement_eed
    FROM expired_codes ec
    CROSS JOIN refresh_parameters rp
) retirements
ON rx.codesystem = retirements.codesystem
AND rx.code = retirements.code
AND rx.esd = retirements.esd
AND rx.eed IS NULL
WHEN MATCHED THEN UPDATE SET
    rx.add_end = 'E',
    rx.eed = retirements.retirement_eed;
