#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
        ${ROOT_DIR}/verification/tb/formal_wbb4_cdc.sv;
    hierarchy -check -top formal_wbb4_cdc;
    proc;
    setattr -mod -unset keep_hierarchy *cdc_gray_reg* *cdc_sync_2ff* *rst_sync_aasd*;
    flatten;
    select formal_wbb4_cdc;
    connect -port u_whitebox mon_rst_src_all       u_dut.u_wb_b4_cdc.u_reset_ctrlr.rst_src_all;
    connect -port u_whitebox mon_rst_dst_all       u_dut.u_wb_b4_cdc.u_reset_ctrlr.rst_dst_all;
    connect -port u_whitebox mon_sw_rst_pend_q     u_dut.u_wb_b4_cdc.u_reset_ctrlr.sw_rst_pend_q;
    connect -port u_whitebox mon_src_state_q       u_dut.u_wb_b4_cdc.u_reset_ctrlr.src_state_q;
    connect -port u_whitebox mon_rst_wb            u_dut.rst_fab_aasd;
    connect -port u_whitebox mon_rst_slv           u_dut.rst_dll_aasd;
    connect -port u_whitebox mon_isolate_wb        u_dut.u_wb_b4_cdc.isolate_wb;
    connect -port u_whitebox mon_isolate_slv       u_dut.u_wb_b4_cdc.isolate_slv;
    connect -port u_whitebox mon_clr_wb            u_dut.u_wb_b4_cdc.clr_wb;
    connect -port u_whitebox mon_clr_slv           u_dut.u_wb_b4_cdc.clr_slv;
    connect -port u_whitebox mon_resp_timeout_q    u_dut.u_wb_b4_cdc.resp_timeout_fire_q;
    connect -port u_whitebox mon_outstanding_cnt   u_dut.u_wb_b4_cdc.outstanding_cnt_q;
    connect -port u_whitebox mon_discard_cnt       u_dut.u_wb_b4_cdc.discard_cnt_q;
    connect -port u_whitebox mon_slv_inflight_cnt  u_dut.u_wb_b4_cdc.slv_inflight_cnt_q;
    connect -port u_whitebox mon_req_fifo_empty    u_dut.u_wb_b4_cdc.req_fifo_empty;
    connect -port u_whitebox mon_resp_fifo_empty   u_dut.u_wb_b4_cdc.resp_fifo_empty;
    connect -port u_whitebox mon_m_wb_cyc          u_dut.dll_wb_cyc;
    connect -port u_whitebox mon_m_wb_stb          u_dut.dll_wb_stb;
    connect -port u_whitebox mon_m_wb_we           u_dut.dll_wb_we;
    connect -port u_whitebox mon_m_wb_adr          u_dut.dll_wb_adr;
    connect -port u_whitebox mon_m_wb_dat          u_dut.dll_wb_wdat;
    connect -port u_whitebox mon_m_wb_stall        u_dut.dll_wb_stall;
    connect -port u_whitebox mon_req_wptr_gray_q   u_dut.u_wb_b4_cdc.u_req_fifo.wptr_gray_q;
    connect -port u_whitebox mon_req_wptr_gray_d   u_dut.u_wb_b4_cdc.u_req_fifo.wptr_gray_d;
    connect -port u_whitebox mon_req_wptr_bin_q    u_dut.u_wb_b4_cdc.u_req_fifo.wptr_bin_q;
    connect -port u_whitebox mon_req_rptr_gray_q   u_dut.u_wb_b4_cdc.u_req_fifo.rptr_gray_q;
    connect -port u_whitebox mon_req_rptr_gray_d   u_dut.u_wb_b4_cdc.u_req_fifo.rptr_gray_d;
    connect -port u_whitebox mon_req_rptr_bin_q    u_dut.u_wb_b4_cdc.u_req_fifo.rptr_bin_q;
    connect -port u_whitebox mon_resp_wptr_gray_q  u_dut.u_wb_b4_cdc.u_resp_fifo.wptr_gray_q;
    connect -port u_whitebox mon_resp_wptr_gray_d  u_dut.u_wb_b4_cdc.u_resp_fifo.wptr_gray_d;
    connect -port u_whitebox mon_resp_wptr_bin_q   u_dut.u_wb_b4_cdc.u_resp_fifo.wptr_bin_q;
    connect -port u_whitebox mon_resp_rptr_gray_q  u_dut.u_wb_b4_cdc.u_resp_fifo.rptr_gray_q;
    connect -port u_whitebox mon_resp_rptr_gray_d  u_dut.u_wb_b4_cdc.u_resp_fifo.rptr_gray_d;
    connect -port u_whitebox mon_resp_rptr_bin_q   u_dut.u_wb_b4_cdc.u_resp_fifo.rptr_bin_q;
    select -clear;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    prep -top formal_wbb4_cdc;
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
echo " Running Unbounded Temporal k-Induction Proof (t -> infinity, Yices2)..."
echo "======================================================================"
INDUCT_SMT2="${TMP_DIR}/formal_wbb4_cdc_induct.smt2"
yosys -q -p "
    read_verilog -sv -formal \
        ${ROOT_DIR}/rtl/cdc_gray_reg.sv \
        ${ROOT_DIR}/rtl/cdc_sync_2ff.sv \
        ${ROOT_DIR}/rtl/rst_sync_aasd.sv \
        ${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv \
        ${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv \
        ${ROOT_DIR}/rtl/wb_b4_cdc.sv \
        ${ROOT_DIR}/verification/tb/formal_wbb4_cdc.sv;
    hierarchy -check -top formal_wbb4_cdc_induct;
    proc;
    setattr -mod -unset keep_hierarchy *cdc_gray_reg* *cdc_sync_2ff* *rst_sync_aasd*;
    flatten;
    select formal_wbb4_cdc_induct;
    connect -port u_induct_wb mon_rst_src_all      u_dut.u_reset_ctrlr.rst_src_all;
    connect -port u_induct_wb mon_rst_dst_all      u_dut.u_reset_ctrlr.rst_dst_all;
    connect -port u_induct_wb mon_src_state_q      u_dut.u_reset_ctrlr.src_state_q;
    connect -port u_induct_wb mon_dst_evt_n_q      u_dut.u_reset_ctrlr.dst_evt_n_q;
    connect -port u_induct_wb mon_isolate_wb       u_dut.isolate_wb;
    connect -port u_induct_wb mon_isolate_slv      u_dut.isolate_slv;
    connect -port u_induct_wb mon_clr_wb           u_dut.clr_wb;
    connect -port u_induct_wb mon_clr_slv          u_dut.clr_slv;
    connect -port u_induct_wb mon_req_wptr_gray_q  u_dut.u_req_fifo.wptr_gray_q;
    connect -port u_induct_wb mon_req_wptr_gray_d  u_dut.u_req_fifo.wptr_gray_d;
    connect -port u_induct_wb mon_req_wptr_bin_q   u_dut.u_req_fifo.wptr_bin_q;
    connect -port u_induct_wb mon_req_rptr_gray_q  u_dut.u_req_fifo.rptr_gray_q;
    connect -port u_induct_wb mon_req_rptr_gray_d  u_dut.u_req_fifo.rptr_gray_d;
    connect -port u_induct_wb mon_req_rptr_bin_q   u_dut.u_req_fifo.rptr_bin_q;
    connect -port u_induct_wb mon_resp_wptr_gray_q u_dut.u_resp_fifo.wptr_gray_q;
    connect -port u_induct_wb mon_resp_wptr_gray_d u_dut.u_resp_fifo.wptr_gray_d;
    connect -port u_induct_wb mon_resp_wptr_bin_q  u_dut.u_resp_fifo.wptr_bin_q;
    connect -port u_induct_wb mon_resp_rptr_gray_q u_dut.u_resp_fifo.rptr_gray_q;
    connect -port u_induct_wb mon_resp_rptr_gray_d u_dut.u_resp_fifo.rptr_gray_d;
    connect -port u_induct_wb mon_resp_rptr_bin_q  u_dut.u_resp_fifo.rptr_bin_q;
    select -clear;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    prep -top formal_wbb4_cdc_induct;
    clk2fflogic;
    opt_clean;
    write_smt2 -wires ${INDUCT_SMT2};
"
yosys-smtbmc -s yices -t 8 --presat "${INDUCT_SMT2}"
yosys-smtbmc -s yices -i -t 8 --presat "${INDUCT_SMT2}"

echo "======================================================================"
echo " Running Formal RTL-to-Gate Equivalence Proof (FIFO_DEPTH_LOG2 = 3, 2, 1)..."
echo "======================================================================"
LIB_PATH="${PDK_ROOT:-$HOME/.ciel/ihp-sg13/ihp-sg13cmos5l}/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
for depth_log2 in 3 2 1; do
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
        chparam -set FIFO_DEPTH_LOG2 ${depth_log2} wbb4_cdc_top;
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
        chparam -set FIFO_DEPTH_LOG2 ${depth_log2} wbb4_cdc_top;
        synth -nofsm -top wbb4_cdc_top;
        setattr -mod -unset keep_hierarchy *;
        flatten;
        dfflibmap -liberty ${LIB_PATH};
        abc -liberty ${LIB_PATH};
        hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
        opt_clean -purge;
        write_verilog -noattr -noexpr ${TMP_DIR}/gate_netlist_d${depth_log2}.v;

        design -reset;
        read_liberty -ignore_miss_func ${LIB_PATH};
        read_verilog ${TMP_DIR}/gate_netlist_d${depth_log2}.v;
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
    echo "Formal RTL-to-Gate Equivalence Proof (wbb4_cdc_top, FIFO_DEPTH_LOG2=${depth_log2}): PASSED (100% proven)"
done

echo "======================================================================"
echo " Running sv2v IEEE 1364-2001 Transpilation, -g2001 Lint & Formal LEC..."
echo "======================================================================"
SV2V_BIN="${SV2V_BIN:-$HOME/.local/bin/sv2v}"
"${SV2V_BIN}" \
    "${ROOT_DIR}/rtl/cdc_gray_reg.sv" \
    "${ROOT_DIR}/rtl/cdc_sync_2ff.sv" \
    "${ROOT_DIR}/rtl/rst_sync_aasd.sv" \
    "${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv" \
    "${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv" \
    "${ROOT_DIR}/rtl/wb_b4_cdc.sv" \
    "${ROOT_DIR}/rtl/wbb4_cdc_test_regfile.sv" \
    "${ROOT_DIR}/rtl/wbb4_cdc_top.sv" \
    > "${TMP_DIR}/wbb4_cdc_sv2v.v"

/usr/bin/iverilog -g2001 -Wall -s wbb4_cdc_top -o "${TMP_DIR}/wbb4_cdc_sv2v.vvp" "${TMP_DIR}/wbb4_cdc_sv2v.v"
echo "Strict IEEE 1364-2001 (iverilog -g2001 -Wall) compilation: PASSED"

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
    design -stash sv_gold;

    read_verilog ${TMP_DIR}/wbb4_cdc_sv2v.v;
    prep -top wbb4_cdc_top;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    memory_map;
    async2sync;
    opt_expr;
    opt_merge;
    opt_dff;
    opt_clean;
    design -stash v2001_gate;

    design -copy-from sv_gold -as gold wbb4_cdc_top;
    design -copy-from v2001_gate -as gate wbb4_cdc_top;
    equiv_make gold gate equiv;
    prep -top equiv;
    opt_clean;
    equiv_simple -seq 5;
    equiv_induct -seq 5;
    equiv_status -assert o:*;
"
echo "Formal SV-to-Verilog-2001 (sv2v) Equivalence Proof (wbb4_cdc_top): PASSED (100% proven)"


