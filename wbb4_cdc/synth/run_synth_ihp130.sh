#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_PATH="${PDK_ROOT:-$HOME/.ciel/ihp-sg13/ihp-sg13cmos5l}/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
STAT_LOG="$(mktemp /tmp/wbb4_cdc_stat_XXXXXX.txt)"
trap 'rm -f "${STAT_LOG}"' EXIT

FLATTEN_OPT="-flatten"
if [[ "${1:-}" == "--no-flatten" ]]; then
    FLATTEN_OPT=""
fi

yosys -q -p "
    read_liberty -lib ${LIB_PATH};
    read_verilog -sv \
        ${ROOT_DIR}/rtl/cdc_gray_reg.sv \
        ${ROOT_DIR}/rtl/cdc_sync_2ff.sv \
        ${ROOT_DIR}/rtl/rst_sync_aasd.sv \
        ${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv \
        ${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv \
        ${ROOT_DIR}/rtl/wb_b4_cdc.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_test_regfile.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_top.sv;
    synth ${FLATTEN_OPT} -top wbb4_cdc_top;
    dfflibmap -liberty ${LIB_PATH};
    abc -liberty ${LIB_PATH};
    hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
    opt_clean;
    check -assert;
    tee -o ${STAT_LOG} stat -liberty ${LIB_PATH};
"
cat "${STAT_LOG}"
