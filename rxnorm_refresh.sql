-- ======================================================
-- RxNorm monthly refresh process
-- This script identifies new RxNorm-to-NDC mappings to add,
-- and active codes to retire from the reference table.
--
-- Assumptions:
--   * ref_id is generated automatically by the target table, or may be NULL on insert.
--   * note is optional metadata and is set to NULL by default in this procedure.
--   * Replace the hard-coded EED value before running the retirement step.
-- ======================================================

-- ======================================================
-- STEP 1: create RxNorm temp table from source text files
-- This view produces a curated list of RxNorm drug codes mapped to NDCs.
-- ======================================================
CREATE OR REPLACE TEMP VIEW current_month_rxnorm AS
SELECT DISTINCT
    'RXNORM_DRUG_CODE' AS codesystem,
    rs.atv AS code,
    rc.str AS description
FROM ca_phm_stg.bronze_ca_phm_ref.rxnsat rs
JOIN ca_phm_stg.bronze_ca_phm_ref.rxnconso rc
  ON rs.rxaui = rc.rxaui
WHERE rs.atn = 'NDC'
  AND rc.sab = 'RXNORM'
  AND rc.tty IN ('SCD', 'SBD', 'GPCK', 'BPCK');

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
    current_date() AS esd,
    NULL AS note
FROM current_month_rxnorm cm
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
-- STEP 5: append end-dated codes into rxnorm_drug_code
-- This inserts retirement rows for codes that should become inactive.
-- Replace the EED literal below with the appropriate monthly cutoff date.
-- ======================================================
INSERT INTO ca_phm_stg.caphm_sandbox_reference_drug.rxnorm_drug_code (
    add_end,
    codesystem,
    code,
    description,
    esd,
    eed,
    note
)
SELECT
    add_end,
    codesystem,
    code,
    description,
    esd,
    DATE '2026-08-01' AS eed,
    note
FROM expired_codes;
