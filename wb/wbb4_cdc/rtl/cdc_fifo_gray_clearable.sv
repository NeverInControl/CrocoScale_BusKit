// ==============================================================================
// Module: cdc_fifo_gray_clearable
// Description:
//   Parameterized Dual-Clock Clearable Gray-Code Asynchronous FIFO with
//   Freeze-Isolate-Then-Clear RDC protection.
// ==============================================================================

`default_nettype none

module cdc_fifo_gray_clearable #(
    parameter int DATA_W      = 8,
    parameter int DEPTH_LOG2  = 3,
    parameter int SYNC_STAGES = 2
) (
    // Write Clock Domain
    input  wire                   clk_wr_i,
    input  wire                   rst_wr_i,
    input  wire                   clr_wr_i,
    input  wire                   isolate_wr_i,
    input  wire                   wr_en_i,
    input  wire  [DATA_W-1:0]     wr_data_i,
    output logic                  full_o,
    output logic [DEPTH_LOG2:0]   used_entries_wr_o,

    // Read Clock Domain
    input  wire                   clk_rd_i,
    input  wire                   rst_rd_i,
    input  wire                   clr_rd_i,
    input  wire                   isolate_rd_i,
    input  wire                   rd_en_i,
    output logic [DATA_W-1:0]     rd_data_o,
    output logic                  empty_o
);

    localparam int DEPTH = 1 << DEPTH_LOG2;
    localparam int PTR_W = DEPTH_LOG2 + 1;

    // --------------------------------------------------------------------------
    // Non-Resettable Flip-Flop Storage Array & Write Domain Pointer Logic
    // --------------------------------------------------------------------------
    logic [DATA_W-1:0] mem_q [0:DEPTH-1];

    logic [PTR_W-1:0]  wptr_bin_q;
    logic [PTR_W-1:0]  wptr_gray_q;
    logic [PTR_W-1:0]  rptr_gray_in_wr;
    wire  [PTR_W-1:0]  rptr_bin_in_wr;

`ifdef __ICARUS__
    initial begin
        wptr_bin_q = '0;
    end
`endif

    wire               do_write    = wr_en_i && !full_o && !isolate_wr_i && !clr_wr_i;
    wire  [PTR_W-1:0]  wptr_bin_d  = wptr_bin_q + (do_write ? 1'b1 : 1'b0);
    wire  [PTR_W-1:0]  wptr_gray_d = (wptr_bin_d >> 1) ^ wptr_bin_d;

    always_ff @(posedge clk_wr_i) begin
        if (do_write) begin
            mem_q[wptr_bin_q[DEPTH_LOG2-1:0]] <= wr_data_i;
        end
    end

    always_ff @(posedge clk_wr_i) begin
        if (clr_wr_i) begin
            wptr_bin_q <= '0;
        end else if (!isolate_wr_i) begin
            wptr_bin_q <= wptr_bin_d;
        end
    end

    cdc_gray_reg #(
        .WIDTH (PTR_W)
    ) u_launch_wptr (
        .clk_i     (clk_wr_i),
        .clr_i     (clr_wr_i),
        .isolate_i (isolate_wr_i),
        .gray_d_i  (wptr_gray_d),
        .gray_q_o  (wptr_gray_q)
    );

    genvar b;
    generate
        for (b = 0; b < PTR_W; b = b + 1) begin : gen_gray2bin
            assign rptr_bin_in_wr[b] = ^(rptr_gray_in_wr >> b);
        end
    endgenerate

    assign used_entries_wr_o = (isolate_wr_i || clr_wr_i) ? '0 : (wptr_bin_q - rptr_bin_in_wr);
    assign full_o            = isolate_wr_i || clr_wr_i || (used_entries_wr_o == PTR_W'(DEPTH));

    // --------------------------------------------------------------------------
    // Read Domain Pointer Logic & FWFT Output
    // --------------------------------------------------------------------------
    logic [PTR_W-1:0] rptr_bin_q;
    logic [PTR_W-1:0] rptr_gray_q;
    logic [PTR_W-1:0] wptr_gray_in_rd;

`ifdef __ICARUS__
    initial begin
        rptr_bin_q = '0;
    end
`endif

    wire              do_read     = rd_en_i && !empty_o && !isolate_rd_i && !clr_rd_i;
    wire  [PTR_W-1:0] rptr_bin_d  = rptr_bin_q + (do_read ? 1'b1 : 1'b0);
    wire  [PTR_W-1:0] rptr_gray_d = (rptr_bin_d >> 1) ^ rptr_bin_d;

    always_ff @(posedge clk_rd_i) begin
        if (clr_rd_i) begin
            rptr_bin_q <= '0;
        end else if (!isolate_rd_i) begin
            rptr_bin_q <= rptr_bin_d;
        end
    end

    cdc_gray_reg #(
        .WIDTH (PTR_W)
    ) u_launch_rptr (
        .clk_i     (clk_rd_i),
        .clr_i     (clr_rd_i),
        .isolate_i (isolate_rd_i),
        .gray_d_i  (rptr_gray_d),
        .gray_q_o  (rptr_gray_q)
    );

    assign empty_o   = isolate_rd_i || clr_rd_i || (rptr_gray_q == wptr_gray_in_rd);
    assign rd_data_o = empty_o ? '0 : mem_q[rptr_bin_q[DEPTH_LOG2-1:0]];

    // --------------------------------------------------------------------------
    // Gray Pointer 2-FF Synchronizers
    // --------------------------------------------------------------------------
    cdc_sync_2ff #(
        .WIDTH       (PTR_W),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_wptr_to_rd (
        .clk_i (clk_rd_i),
        .rst_i (rst_rd_i),
        .d_i   (wptr_gray_q),
        .q_o   (wptr_gray_in_rd)
    );

    cdc_sync_2ff #(
        .WIDTH       (PTR_W),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_rptr_to_wr (
        .clk_i (clk_wr_i),
        .rst_i (rst_wr_i),
        .d_i   (rptr_gray_q),
        .q_o   (rptr_gray_in_wr)
    );

    // --------------------------------------------------------------------------
    // Continuous Simulation RDC & Gray-Code Hamming-Distance Checker
    // --------------------------------------------------------------------------
`ifdef SIM_CDC_JITTER
    logic [PTR_W-1:0] wptr_gray_prev_q = '0;
    logic [PTR_W-1:0] rptr_gray_prev_q = '0;
    wire  [PTR_W-1:0] wptr_diff        = wptr_gray_q ^ wptr_gray_prev_q;
    wire  [PTR_W-1:0] rptr_diff        = rptr_gray_q ^ rptr_gray_prev_q;

    always @(posedge clk_wr_i) begin
        wptr_gray_prev_q <= wptr_gray_q;
        if (!isolate_rd_i && ((wptr_diff & (wptr_diff - 1'b1)) != '0)) begin
            $display("[RDC/GRAY VIOLATION @ %0t] wptr_gray_q jumped >1 bit (%b -> %b) while isolate_rd_i=0!",
                     $time, wptr_gray_prev_q, wptr_gray_q);
            $finish;
        end
    end

    always @(posedge clk_rd_i) begin
        rptr_gray_prev_q <= rptr_gray_q;
        if (!isolate_wr_i && ((rptr_diff & (rptr_diff - 1'b1)) != '0)) begin
            $display("[RDC/GRAY VIOLATION @ %0t] rptr_gray_q jumped >1 bit (%b -> %b) while isolate_wr_i=0!",
                     $time, rptr_gray_prev_q, rptr_gray_q);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire

