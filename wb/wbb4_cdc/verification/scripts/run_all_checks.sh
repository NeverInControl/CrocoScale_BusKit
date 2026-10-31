#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/wbb4_cdc_checks_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "======================================================================"
echo " [1/4] Behavioral RTL Simulation + Jitter (FIFO_DEPTH_LOG2 = 3, 2, 1)"
echo "======================================================================"
for depth_log2 in 3 2 1; do
    echo ">>> Testing FIFO_DEPTH_LOG2 = ${depth_log2} ($((1 << depth_log2)) entries) <<<"
    for part in tb_part1_bursts_and_skew tb_part2_resets_and_aborts tb_part3_watchdogs_and_stress; do
        (
            cd "${ROOT_DIR}"
            /usr/bin/iverilog -g2012 -DSIM_CDC_JITTER \
                -P${part}.FIFO_DEPTH_LOG2=${depth_log2} \
                -o "${TMP_DIR}/${part}_d${depth_log2}.vvp" \
                -c "${ROOT_DIR}/wbb4_cdc_top.f" \
                "${ROOT_DIR}/verification/tb/${part}.sv"
        )
        /usr/bin/vvp "${TMP_DIR}/${part}_d${depth_log2}.vvp"
    done
done

echo "======================================================================"
echo " [2/4] Gate-Level Simulation on ihp-sg13cmos5l Standard Cells"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_gls_ihp130.sh"

echo "======================================================================"
echo " [3/4] 3-Corner Static Timing Analysis & SDC Wildcard Verification"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_sta_ihp130.sh"

echo "======================================================================"
echo " [4/4] Multi-Clock Formal BMC, Cover & RTL-to-Gate Equivalence (LEC)"
echo "======================================================================"
bash "${SCRIPT_DIR}/run_formal.sh" 50

echo "======================================================================"
echo " ALL wbb4_cdc VERIFICATION CHECKS PASSED SUCCESSFULLY"
echo "======================================================================"
