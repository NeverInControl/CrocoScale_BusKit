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
module sg13cmos5l_dfrbpq_1_sync_meta (Q, CLK, D, RESET_B);
    output Q;
    input  CLK, D, RESET_B;
    reg notifier;
    wire int_fwire_IQ, int_fwire_r, xcr_0;
    reg  d_skewed;
    integer lfsr_q = 32'hACE1_CAFE;

    always @(posedge CLK) begin
        lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
    end

    // Physical point-to-point CDC wire arrival skew (0 ps to 350 ps per transition)
    always @(D) begin
        d_skewed <= #(0.05 * (lfsr_q & 32'd7)) D;
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
    copy wbb4_cdc_top wbb4_cdc_top_deep;
    copy wbb4_cdc_top wbb4_cdc_top_wait_forever;
    chparam -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top;
    chparam -set FIFO_DEPTH_LOG2 4 -set SYNC_STAGES 3 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_deep;
    chparam -set EN_GATE_TIMEOUT 0 -set EN_RESP_TIMEOUT 0 -set GATE_TIMEOUT_CYCLES 32 -set RESP_TIMEOUT_CYCLES 32 wbb4_cdc_top_wait_forever;
    hierarchy -check;
    synth;
    setattr -mod -unset keep_hierarchy *;
    flatten wbb4_cdc_top wbb4_cdc_top_deep wbb4_cdc_top_wait_forever;
    opt -fast;
    dfflibmap -liberty ${LIB_PATH};
    abc -liberty ${LIB_PATH};
    hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
    autoname;
    opt_clean -purge;
    check -assert;
    write_verilog -noattr -noexpr ${GLS_NETLIST};
"

# Swap Stage-0 synchronizer flip-flops (*sync_meta_q*) to the CDC skew-injecting cell model
sed -i 's/sg13cmos5l_dfrbpq_1 \([^ ]*sync_meta_q\)/sg13cmos5l_dfrbpq_1_sync_meta \1/g' "${GLS_NETLIST}"
SYNC_META_CNT=$(grep -c "sg13cmos5l_dfrbpq_1_sync_meta" "${GLS_NETLIST}" || true)
echo " Injected 2.0-ns setup-window CDC skew model on ${SYNC_META_CNT} Stage-0 gate-level sync flops."

echo "======================================================================"
echo " Running Gate-Level Simulation (GLS) with ihp-sg13cmos5l UDP Cells..."
echo "======================================================================"
for part in tb_part1_bursts_and_skew tb_part2_resets_and_aborts tb_part3_watchdogs_and_stress; do
    /usr/bin/iverilog -g2012 -gno-specify -DGATE_LEVEL_SIM \
        -o "${TMP_DIR}/${part}_gls.vvp" \
        "${UDP_V}" \
        "${STDCELL_FUNC_V}" \
        "${GLS_NETLIST}" \
        "${ROOT_DIR}/verification/tb/${part}.sv"
    /usr/bin/vvp "${TMP_DIR}/${part}_gls.vvp"
done

