#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PDK_STDCELL_DIR="${PDK_ROOT:-$HOME/.ciel/ihp-sg13/ihp-sg13cmos5l}/libs.ref/sg13cmos5l_stdcell"
LIB_PATH="${PDK_STDCELL_DIR}/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
UDP_V="${PDK_STDCELL_DIR}/verilog/sg13cmos5l_udp.v"
STDCELL_V="${PDK_STDCELL_DIR}/verilog/sg13cmos5l_stdcell.v"

TMP_DIR="$(mktemp -d /tmp/wbb4_cdc_gls_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

GLS_NETLIST="${TMP_DIR}/wbb4_cdc_gls_netlist.v"
STDCELL_FUNC_V="${TMP_DIR}/sg13cmos5l_stdcell_func.v"

# Map delayed_* specify-check signals to raw pins, strip unsupported specify blocks for Icarus,
# add non-zero #0.10 ns CLK->Q propagation delay to sg13cmos5l_dfrbpq_1, and provide
# sg13cmos5l_dfrbpq_1_sync_meta with 2.0 ns setup-window CDC skew/jitter injection for Stage-0 sync flops.
sed -e 's/delayed_\([A-Za-z0-9_]*\)/\1/g' \
    -e '/^[[:space:]]*specify/,/^[[:space:]]*endspecify/d' \
    -e 's/buf (Q, int_fwire_IQ);/buf #0.10 (Q, int_fwire_IQ);/g' \
    "${STDCELL_V}" > "${STDCELL_FUNC_V}"

cat << 'EOF' >> "${STDCELL_FUNC_V}"
`timescale 1ns / 1ps
module sg13cmos5l_dfrbpq_1_sync_meta #(
    parameter integer SEED = 32'hACE1_CAFE
) (Q, CLK, D, RESET_B);
    output Q;
    input  CLK, D, RESET_B;
    reg notifier;
    wire int_fwire_IQ, int_fwire_r, xcr_0;
    reg  d_skewed;
    integer lfsr_q;

    initial begin
        lfsr_q = SEED;
    end

    always @(posedge CLK) begin
        lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]} ^ {31'd0, D};
    end

    // Uncorrelated per-bit CDC wire arrival skew spanning 0.00 ns to 1.75 ns (the full 2.0-ns SDC window)
    always @(D) begin
        d_skewed <= #(0.25 * (lfsr_q & 32'd7)) D;
    end

    not (int_fwire_r, RESET_B);
    buf (xcr_0, 0);
    ihp_dff_r (int_fwire_IQ, notifier, CLK, d_skewed, int_fwire_r, xcr_0);
    buf #0.10 (Q, int_fwire_IQ);
endmodule
EOF

echo "======================================================================"
echo " Synthesizing Gate-Level Netlists for ihp-sg13cmos5l GLS..."
echo "======================================================================"
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
    copy wbb4_cdc_top wbb4_cdc_top_d2;
    copy wbb4_cdc_top wbb4_cdc_top_d1;
    copy wbb4_cdc_top wbb4_cdc_top_deep;
    copy wbb4_cdc_top wbb4_cdc_top_wait_forever;
    chparam -set FIFO_DEPTH_LOG2 3 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top;
    chparam -set FIFO_DEPTH_LOG2 2 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_d2;
    chparam -set FIFO_DEPTH_LOG2 1 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_d1;
    chparam -set FIFO_DEPTH_LOG2 4 -set SYNC_STAGES 3 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_deep;
    chparam -set EN_GATE_TIMEOUT 0 -set EN_RESP_TIMEOUT 0 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_wait_forever;
    hierarchy -check;
    synth;
    setattr -mod -unset keep_hierarchy *;
    flatten wbb4_cdc_top wbb4_cdc_top_d2 wbb4_cdc_top_d1 wbb4_cdc_top_deep wbb4_cdc_top_wait_forever;
    opt -fast;
    dfflibmap -liberty ${LIB_PATH};
    abc -liberty ${LIB_PATH};
    hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
    autoname;
    opt_clean -purge;
    check -assert;
    write_verilog -noattr -noexpr ${GLS_NETLIST};
"

# Swap Stage-0 synchronizer flip-flops (*sync_meta_q*) to the CDC skew-injecting cell model with unique per-flop seeds
awk '
    /sg13cmos5l_dfrbpq_1 [^ ]*sync_meta_q/ {
        seed_cnt++;
        sub(/sg13cmos5l_dfrbpq_1/, sprintf("sg13cmos5l_dfrbpq_1_sync_meta #(.SEED(%d))", 135791 + seed_cnt * 7919));
    }
    { print }
' "${GLS_NETLIST}" > "${GLS_NETLIST}.seeded" && mv "${GLS_NETLIST}.seeded" "${GLS_NETLIST}"
SYNC_META_CNT=$(grep -c "sg13cmos5l_dfrbpq_1_sync_meta" "${GLS_NETLIST}" || true)
echo " Injected uncorrelated per-bit 2.0-ns setup-window CDC skew & metastability model on ${SYNC_META_CNT} Stage-0 sync flops."

echo "======================================================================"
echo " Running Gate-Level Simulation (GLS) across FIFO_DEPTH_LOG2 = 3, 2, 1..."
echo "======================================================================"
for depth_log2 in 3 2 1; do
    gls_mod="wbb4_cdc_top"
    if [[ "${depth_log2}" == "2" ]]; then gls_mod="wbb4_cdc_top_d2"; fi
    if [[ "${depth_log2}" == "1" ]]; then gls_mod="wbb4_cdc_top_d1"; fi
    echo ">>> GLS FIFO_DEPTH_LOG2 = ${depth_log2} (${gls_mod}, $((1 << depth_log2)) entries) <<<"
    for part in tb_part1_bursts_and_skew tb_part2_resets_and_aborts tb_part3_watchdogs_and_stress; do
        /usr/bin/iverilog -g2012 -gno-specify -DGATE_LEVEL_SIM \
            -DGLS_DUT_NAME=${gls_mod} \
            -P${part}.FIFO_DEPTH_LOG2=${depth_log2} \
            -o "${TMP_DIR}/${part}_gls_d${depth_log2}.vvp" \
            "${UDP_V}" \
            "${STDCELL_FUNC_V}" \
            "${GLS_NETLIST}" \
            "${ROOT_DIR}/verification/tb/${part}.sv"
        /usr/bin/vvp "${TMP_DIR}/${part}_gls_d${depth_log2}.vvp"
    done
done

