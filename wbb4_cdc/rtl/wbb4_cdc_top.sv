// ==============================================================================
// Module: wbb4_cdc_top
// Description:
//   Top-level integration wrapper for the IHP 130nm eFPGA custom block
//   (18 fabric pins + 1 external reset pad + internal DLL clock).
//
//   Responsibilities:
//   - Synchronizes raw off-chip rst_dll_pad_i and fabric rst_fab_i into local
//     AASD resets (rst_fab_aasd, rst_dll_aasd) via rst_sync_aasd bridges.
//   - Feeds rst_dll_aasd simultaneously to both wb_b4_cdc and
//     wbb4_cdc_test_regfile so they exit reset on the exact same clk_dll_i edge.
// ==============================================================================

`default_nettype none

module wbb4_cdc_top #(
    parameter int ADDR_W              = 2,
    parameter int DATA_W              = 4,
    parameter int FIFO_DEPTH_LOG2     = 3,
    parameter int SYNC_STAGES         = 2,
    parameter int EN_GATE_TIMEOUT     = 1,
    parameter int GATE_TIMEOUT_CYCLES = 256,
    parameter int EN_RESP_TIMEOUT     = 1,
    parameter int RESP_TIMEOUT_CYCLES = 256
) (
    // --------------------------------------------------------------------------
    // 18 eFPGA Fabric Boundary Pins
    // --------------------------------------------------------------------------
    input  wire               clk_fab_i,     // Pin 1
    input  wire               rst_fab_i,     // Pin 2
    input  wire               wb_cyc_i,      // Pin 3
    input  wire               wb_stb_i,      // Pin 4
    input  wire               wb_we_i,       // Pin 5
    input  wire  [ADDR_W-1:0] wb_adr_i,      // Pins 6..7   (2b)
    input  wire  [DATA_W-1:0] wb_dat_i,      // Pins 8..11  (4b)
    output logic              wb_stall_o,    // Pin 12
    output logic              wb_ack_o,      // Pin 13
    output logic              wb_err_o,      // Pin 14
    output logic [DATA_W-1:0] wb_dat_o,      // Pins 15..18 (4b)

    // --------------------------------------------------------------------------
    // DLL Clock & 1 Direct Chip Pad
    // --------------------------------------------------------------------------
    input  wire               clk_dll_i,     // Internal wire from Partner DLL
    input  wire               rst_dll_pad_i  // Direct External Chip Pad
);

    logic rst_fab_aasd;
    logic rst_dll_aasd;

    rst_sync_aasd #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_rst_sync_fab (
        .clk_i       (clk_fab_i),
        .rst_async_i (rst_fab_i),
        .rst_sync_o  (rst_fab_aasd)
    );

    rst_sync_aasd #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_rst_sync_dll (
        .clk_i       (clk_dll_i),
        .rst_async_i (rst_dll_pad_i),
        .rst_sync_o  (rst_dll_aasd)
    );

    logic              dll_wb_cyc;
    logic              dll_wb_stb;
    logic              dll_wb_we;
    logic [ADDR_W-1:0] dll_wb_adr;
    logic [DATA_W-1:0] dll_wb_wdat;
    logic              dll_wb_stall;
    logic              dll_wb_ack;
    logic              dll_wb_err;
    logic [DATA_W-1:0] dll_wb_rdat;

    wb_b4_cdc #(
        .ADDR_W              (ADDR_W),
        .DATA_W              (DATA_W),
        .FIFO_DEPTH_LOG2     (FIFO_DEPTH_LOG2),
        .SYNC_STAGES         (SYNC_STAGES),
        .EN_GATE_TIMEOUT     (EN_GATE_TIMEOUT),
        .GATE_TIMEOUT_CYCLES (GATE_TIMEOUT_CYCLES),
        .EN_RESP_TIMEOUT     (EN_RESP_TIMEOUT),
        .RESP_TIMEOUT_CYCLES (RESP_TIMEOUT_CYCLES)
    ) u_wb_b4_cdc (
        .clk_wb_i     (clk_fab_i),
        .rst_wb_i     (rst_fab_aasd),
        .s_wb_cyc_i   (wb_cyc_i),
        .s_wb_stb_i   (wb_stb_i),
        .s_wb_we_i    (wb_we_i),
        .s_wb_adr_i   (wb_adr_i),
        .s_wb_dat_i   (wb_dat_i),
        .s_wb_stall_o (wb_stall_o),
        .s_wb_ack_o   (wb_ack_o),
        .s_wb_err_o   (wb_err_o),
        .s_wb_dat_o   (wb_dat_o),

        .clk_slv_i    (clk_dll_i),
        .rst_slv_i    (rst_dll_aasd),
        .m_wb_cyc_o   (dll_wb_cyc),
        .m_wb_stb_o   (dll_wb_stb),
        .m_wb_we_o    (dll_wb_we),
        .m_wb_adr_o   (dll_wb_adr),
        .m_wb_dat_o   (dll_wb_wdat),
        .m_wb_stall_i (dll_wb_stall),
        .m_wb_ack_i   (dll_wb_ack),
        .m_wb_err_i   (dll_wb_err),
        .m_wb_dat_i   (dll_wb_rdat)
    );

    wbb4_cdc_test_regfile #(
        .ADDR_W (ADDR_W),
        .DATA_W (DATA_W)
    ) u_test_regfile (
        .clk_dll_i  (clk_dll_i),
        .rst_dll_i  (rst_dll_aasd),
        .wb_cyc_i   (dll_wb_cyc),
        .wb_stb_i   (dll_wb_stb),
        .wb_we_i    (dll_wb_we),
        .wb_adr_i   (dll_wb_adr),
        .wb_dat_i   (dll_wb_wdat),
        .wb_stall_o (dll_wb_stall),
        .wb_ack_o   (dll_wb_ack),
        .wb_err_o   (dll_wb_err),
        .wb_dat_o   (dll_wb_rdat)
    );

endmodule

`default_nettype wire
