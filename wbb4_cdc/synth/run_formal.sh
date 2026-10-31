#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/wbb4_cdc_formal_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SMT2_FILE="${TMP_DIR}/formal_wbb4_cdc.smt2"
BMC_STEPS="${1:-50}"

echo "======================================================================"
echo " Preparing Multi-Clock Formal Model (clk2fflogic -> SMT2)..."
echo "======================================================================"
yosys -q -p "
    read_verilog -sv -formal \
        ${ROOT_DIR}/rtl/cdc_gray_reg.sv \
        ${ROOT_DIR}/rtl/cdc_sync_2ff.sv \
        ${ROOT_DIR}/rtl/rst_sync_aasd.sv \
        ${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv \
        ${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv \
        ${ROOT_DIR}/rtl/wb_b4_cdc.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_test_regfile.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_top.sv \
        ${ROOT_DIR}/tb/formal_wbb4_cdc.sv;
    prep -top formal_wbb4_cdc;
    flatten;
    clk2fflogic;
    opt_clean;
    write_smt2 -wires ${SMT2_FILE};
"

echo "======================================================================"
echo " Running Multi-Clock Bounded Model Checking (${BMC_STEPS} Steps, Yices2)..."
echo "======================================================================"
if ! yosys-smtbmc -s yices -t "${BMC_STEPS}" --presat --dump-vlogtb "${TMP_DIR}/cex_tb.v" "${SMT2_FILE}"; then
    echo "--- Counterexample Trace ---"
    cat "${TMP_DIR}/cex_tb.v"
    exit 1
fi

COVER_STEPS=$(( BMC_STEPS < 46 ? 46 : BMC_STEPS ))
echo "======================================================================"
echo " Running Formal Reachability Cover Analysis (${COVER_STEPS} Steps, Yices2)..."
echo "======================================================================"
yosys-smtbmc -s yices -t "${COVER_STEPS}" -c "${SMT2_FILE}"

echo "======================================================================"
echo " Running Formal RTL-to-Gate Equivalence Proof (ihp-sg13cmos5l)..."
echo "======================================================================"
LIB_PATH="${PDK_ROOT:-$HOME/.ciel/ihp-sg13/ihp-sg13cmos5l}/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
yosys -q -p "
    read_verilog -sv \
        ${ROOT_DIR}/rtl/cdc_gray_reg.sv \
        ${ROOT_DIR}/rtl/cdc_sync_2ff.sv \
        ${ROOT_DIR}/rtl/rst_sync_aasd.sv \
        ${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv \
        ${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv \
        ${ROOT_DIR}/rtl/wb_b4_cdc.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_test_regfile.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_top.sv;
    prep -top wbb4_cdc_top;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    memory_map;
    async2sync;
    opt_expr;
    opt_merge;
    opt_dff;
    opt_clean;
    design -stash gold;

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
    synth -nofsm -top wbb4_cdc_top;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    dfflibmap -liberty ${LIB_PATH};
    abc -liberty ${LIB_PATH};
    hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
    opt_clean -purge;
    write_verilog -noattr -noexpr ${TMP_DIR}/gate_netlist.v;

    design -reset;
    read_liberty -ignore_miss_func ${LIB_PATH};
    read_verilog ${TMP_DIR}/gate_netlist.v;
    prep -top wbb4_cdc_top;
    flatten;
    async2sync;
    opt_expr;
    opt_dff;
    opt_clean;
    design -stash gate;

    design -copy-from gold -as gold wbb4_cdc_top;
    design -copy-from gate -as gate wbb4_cdc_top;
    equiv_make gold gate equiv;
    prep -top equiv;
    opt_clean;
    equiv_simple -seq 5;
    equiv_induct -seq 5;
    equiv_status -assert o:*;
"
echo "Formal RTL-to-Gate Equivalence Proof (wbb4_cdc_top): PASSED (100% proven)"

