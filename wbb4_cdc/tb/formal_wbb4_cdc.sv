// ==============================================================================
// Formal Verification Wrapper: formal_wbb4_cdc
// Description:
//   Multi-clock formal verification harness for wbb4_cdc_top using Yosys
//   clk2fflogic + yosys-smtbmc.
// ==============================================================================

`default_nettype none

module formal_wbb4_cdc (
    input wire clk_fab_i,
    input wire clk_dll_i,
    input wire rst_fab_i,
    input wire rst_dll_pad_i
);

    localparam int ADDR_W              = 2;
    localparam int DATA_W              = 4;
    localparam int FIFO_DEPTH_LOG2     = 2;
    localparam int FIFO_DEPTH          = 1 << FIFO_DEPTH_LOG2;
    localparam int CNT_W               = FIFO_DEPTH_LOG2 + 3;
    localparam int SYNC_STAGES         = 2;
    localparam int GATE_TIMEOUT_CYCLES = 4;
    localparam int RESP_TIMEOUT_CYCLES = 4;

    // --------------------------------------------------------------------------
    // Global Formal Step Counter & Power-On Reset Initialization (Steps 0..3)
    // --------------------------------------------------------------------------
    logic [3:0] f_step_q = 4'd0;
    always @($global_clock) begin
        if (f_step_q != 4'hF) begin
            f_step_q <= f_step_q + 4'd1;
        end
    end

    always @(*) begin
        if (f_step_q < 4'd4) begin
            assume (rst_fab_i     == 1'b1);
            assume (rst_dll_pad_i == 1'b1);
            assume (clk_fab_i     == 1'b0);
            assume (clk_dll_i     == 1'b0);
        end
    end

    // Mirror AASD reset synchronizer for the formal Master reference tracker
    logic f_rst_fab_aasd;
    rst_sync_aasd #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_f_rst_sync_fab (
        .clk_i       (clk_fab_i),
        .rst_async_i (rst_fab_i),
        .rst_sync_o  (f_rst_fab_aasd)
    );

    // --------------------------------------------------------------------------
    // Constructive Wishbone B4 Pipelined Master Generator (clk_fab_i Domain)
    // --------------------------------------------------------------------------
    (* anyseq *) wire              f_next_cyc;
    (* anyseq *) wire              f_next_stb;
    (* anyseq *) wire              f_next_we;
    (* anyseq *) wire [ADDR_W-1:0] f_next_adr;
    (* anyseq *) wire [DATA_W-1:0] f_next_dat;

    logic              wb_cyc;
    logic              wb_stb;
    logic              wb_we;
    logic [ADDR_W-1:0] wb_adr;
    logic [DATA_W-1:0] wb_wdat;
    logic              wb_stall;
    logic              wb_ack;
    logic              wb_err;
    logic [DATA_W-1:0] wb_rdat;

    logic [CNT_W-1:0]  f_master_outstanding;

    wbb4_cdc_top #(
        .ADDR_W              (ADDR_W),
        .DATA_W              (DATA_W),
        .FIFO_DEPTH_LOG2     (FIFO_DEPTH_LOG2),
        .SYNC_STAGES         (SYNC_STAGES),
        .EN_GATE_TIMEOUT     (1),
        .GATE_TIMEOUT_CYCLES (GATE_TIMEOUT_CYCLES),
        .EN_RESP_TIMEOUT     (1),
        .RESP_TIMEOUT_CYCLES (RESP_TIMEOUT_CYCLES)
    ) u_dut (
        .clk_fab_i     (clk_fab_i),
        .rst_fab_i     (rst_fab_i),
        .wb_cyc_i      (wb_cyc),
        .wb_stb_i      (wb_stb),
        .wb_we_i       (wb_we),
        .wb_adr_i      (wb_adr),
        .wb_dat_i      (wb_wdat),
        .wb_stall_o    (wb_stall),
        .wb_ack_o      (wb_ack),
        .wb_err_o      (wb_err),
        .wb_dat_o      (wb_rdat),
        .clk_dll_i     (clk_dll_i),
        .rst_dll_pad_i (rst_dll_pad_i)
    );

    wire req_accepted   = wb_cyc && wb_stb && !wb_stall;
    wire resp_delivered = wb_cyc && (wb_ack || wb_err);

    always_ff @(posedge clk_fab_i or posedge f_rst_fab_aasd) begin
        if (f_rst_fab_aasd) begin
            wb_cyc               <= 1'b0;
            wb_stb               <= 1'b0;
            wb_we                <= 1'b0;
            wb_adr               <= '0;
            wb_wdat              <= '0;
            f_master_outstanding <= '0;
        end else begin
            if (!f_next_cyc || !wb_cyc) begin
                f_master_outstanding <= '0;
            end else begin
                if (req_accepted && !resp_delivered) begin
                    f_master_outstanding <= f_master_outstanding + 1'b1;
                end else if (!req_accepted && resp_delivered) begin
                    f_master_outstanding <= f_master_outstanding - 1'b1;
                end
            end

            if (!f_next_cyc) begin
                wb_cyc  <= 1'b0;
                wb_stb  <= 1'b0;
                wb_we   <= 1'b0;
                wb_adr  <= '0;
                wb_wdat <= '0;
            end else if (wb_cyc && wb_stb && wb_stall) begin
                wb_cyc  <= 1'b1;
                wb_stb  <= 1'b1;
                wb_we   <= wb_we;
                wb_adr  <= wb_adr;
                wb_wdat <= wb_wdat;
            end else begin
                wb_cyc  <= 1'b1;
                wb_stb  <= f_next_stb;
                wb_we   <= f_next_we;
                wb_adr  <= f_next_adr;
                wb_wdat <= f_next_dat;
            end
        end
    end

    // --------------------------------------------------------------------------
    // Black-Box End-to-End Formal Data Integrity Scoreboard (SCRATCH_0 / SCRATCH_1)
    // --------------------------------------------------------------------------
    // Tracks expected register values across clean single-beat writes and reads
    // using only top-level ports (no hierarchical references), proving that
    // address, write-enable, write-data, and read-data bits traverse both CDC
    // FIFOs without corruption.
    logic [DATA_W-1:0] f_exp_s0_q;
    logic [DATA_W-1:0] f_exp_s1_q;
    logic              f_s0_known_q;
    logic              f_s1_known_q;
    logic              f_trk_valid_q;
    logic              f_trk_we_q;
    logic              f_trk_adr_bit0_q;
    logic [DATA_W-1:0] f_trk_wdat_q;

    always_ff @(posedge clk_fab_i or posedge f_rst_fab_aasd) begin
        if (f_rst_fab_aasd) begin
            f_exp_s0_q       <= 4'hA;
            f_exp_s1_q       <= 4'h5;
            f_s0_known_q     <= 1'b1;
            f_s1_known_q     <= 1'b1;
            f_trk_valid_q    <= 1'b0;
            f_trk_we_q       <= 1'b0;
            f_trk_adr_bit0_q <= 1'b0;
            f_trk_wdat_q     <= '0;
        end else begin
            if (rst_dll_pad_i) begin
                f_trk_valid_q <= 1'b0;
                if ((f_master_outstanding == '0) && !req_accepted) begin
                    f_exp_s0_q   <= 4'hA;
                    f_exp_s1_q   <= 4'h5;
                    f_s0_known_q <= 1'b1;
                    f_s1_known_q <= 1'b1;
                end else begin
                    f_s0_known_q <= 1'b0;
                    f_s1_known_q <= 1'b0;
                end
            end else if (!f_next_cyc || !wb_cyc || wb_err) begin
                f_trk_valid_q <= 1'b0;
                if ((f_master_outstanding > '0) || req_accepted) begin
                    f_s0_known_q <= 1'b0;
                    f_s1_known_q <= 1'b0;
                end
            end else if (req_accepted) begin
                if ((f_master_outstanding == '0) && !wb_adr[1]) begin
                    f_trk_valid_q    <= 1'b1;
                    f_trk_we_q       <= wb_we;
                    f_trk_adr_bit0_q <= wb_adr[0];
                    f_trk_wdat_q     <= wb_wdat;
                end else begin
                    f_trk_valid_q <= 1'b0;
                    if (wb_we && (wb_adr == 2'h0)) f_s0_known_q <= 1'b0;
                    if (wb_we && (wb_adr == 2'h1)) f_s1_known_q <= 1'b0;
                end
            end else if (resp_delivered) begin
                f_trk_valid_q <= 1'b0;
                if (f_trk_valid_q && wb_ack && (f_master_outstanding == CNT_W'(1)) && f_trk_we_q) begin
                    if (!f_trk_adr_bit0_q) begin
                        f_exp_s0_q   <= f_trk_wdat_q;
                        f_s0_known_q <= 1'b1;
                    end else begin
                        f_exp_s1_q   <= f_trk_wdat_q;
                        f_s1_known_q <= 1'b1;
                    end
                end
            end
        end
    end

    // Sticky flag on $global_clock detecting any post-boot asynchronous reset
    // assertion (even between clk_fab_i edges)
    logic f_post_boot_rst_seen_q = 1'b0;
    always @($global_clock) begin
        if (f_step_q < 4'd4) begin
            f_post_boot_rst_seen_q <= 1'b0;
        end else if (rst_dll_pad_i || rst_fab_i) begin
            f_post_boot_rst_seen_q <= 1'b1;
        end
    end

    // --------------------------------------------------------------------------
    // Top-Level Pin Assertions, Data Scoreboard & Reachability Covers
    // --------------------------------------------------------------------------
    always @($global_clock) begin
        if (f_step_q >= 4'd4) begin
            assert (!(wb_ack && wb_err));
            if (!wb_cyc) begin
                assert (!wb_ack && !wb_err);
            end
            if (!f_rst_fab_aasd) begin
                if (wb_ack || wb_err) begin
                    assert (f_master_outstanding > '0);
                end
                assert (f_master_outstanding <= CNT_W'(2 * FIFO_DEPTH));

                // End-to-End Read Data Integrity Assertion
                if (!f_post_boot_rst_seen_q && !rst_dll_pad_i && !rst_fab_i &&
                    f_trk_valid_q && !f_trk_we_q &&
                    wb_cyc && wb_ack && (f_master_outstanding == CNT_W'(1))) begin
                    if (!f_trk_adr_bit0_q && f_s0_known_q) begin
                        assert (wb_rdat == f_exp_s0_q);
                    end
                    if (f_trk_adr_bit0_q && f_s1_known_q) begin
                        assert (wb_rdat == f_exp_s1_q);
                    end
                end
            end

            cover (wb_ack && (wb_rdat == 4'hA));
            cover (wb_err);
        end
    end

endmodule

`default_nettype wire
