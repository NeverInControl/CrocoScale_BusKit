#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/wbb4_cdc_reg_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "======================================================================"
echo " [1/4] Behavioral RTL Simulation + CDC Jitter (tb_part1..3)"
echo "======================================================================"
for tb in tb_part1_bursts_and_skew tb_part2_resets_and_aborts tb_part3_watchdogs_and_stress; do
    /usr/bin/iverilog -g2012 -DSIM_CDC_JITTER \
        -o "${TMP_DIR}/${tb}.vvp" \
        "${ROOT_DIR}"/rtl/*.sv \
        "${ROOT_DIR}/tb/${tb}.sv"
    /usr/bin/vvp "${TMP_DIR}/${tb}.vvp"
done

echo "======================================================================"
echo " [2/4] IHP 130nm Gate-Level Simulation + Skew Injection (run_gls_ihp130.sh)"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_gls_ihp130.sh"

echo "======================================================================"
echo " [3/4] 3-Corner STA & SDC Wildcard Verification (run_sta_ihp130.sh)"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_sta_ihp130.sh"

echo "======================================================================"
echo " [4/4] Multi-Clock Formal BMC + Cover + RTL-to-Gate LEC (run_formal.sh)"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_formal.sh" "${1:-50}"
