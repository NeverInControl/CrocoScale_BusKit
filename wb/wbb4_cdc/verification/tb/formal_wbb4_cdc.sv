// ==============================================================================
// Formal Verification Wrapper: formal_wbb4_cdc
// Description:
//   Multi-clock formal verification harness for wbb4_cdc_top using Yosys
//   clk2fflogic + yosys-smtbmc. Contains all top-level and white-box formal
//   assertions, bounded recovery proofs, and reachability covers so the RTL
//   files in rtl/ remain 100% pure hardware description.
// ==============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *)
module formal_wbb4_cdc_whitebox #(
    parameter int ADDR_W          = 2,
    parameter int DATA_W          = 4,
    parameter int FIFO_DEPTH_LOG2 = 2
) (
    input wire                              clk_fab_i,
    input wire                              clk_dll_i,
    input wire  [3:0]                       f_step_q,
    input wire                              wb_cyc,
    input wire                              wb_stb,
    input wire                              wb_stall,
    input wire                              wb_ack,

    input wire                              mon_rst_src_all,
    input wire                              mon_rst_dst_all,
    input wire                              mon_sw_rst_pend_q,
    input wire  [1:0]                       mon_src_state_q,

    input wire                              mon_rst_wb,
    input wire                              mon_rst_slv,
    input wire                              mon_isolate_wb,
    input wire                              mon_isolate_slv,
    input wire                              mon_clr_wb,
    input wire                              mon_clr_slv,
    input wire                              mon_resp_timeout_q,
    input wire  [FIFO_DEPTH_LOG2+2:0]       mon_outstanding_cnt,
    input wire  [FIFO_DEPTH_LOG2+2:0]       mon_discard_cnt,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_slv_inflight_cnt,
    input wire                              mon_req_fifo_empty,
    input wire                              mon_resp_fifo_empty,
    input wire                              mon_m_wb_cyc,
    input wire                              mon_m_wb_stb,
    input wire                              mon_m_wb_we,
    input wire  [ADDR_W-1:0]                mon_m_wb_adr,
    input wire  [DATA_W-1:0]                mon_m_wb_dat,
    input wire                              mon_m_wb_stall,

    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_wptr_gray_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_wptr_gray_d,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_wptr_bin_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_rptr_gray_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_rptr_gray_d,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_req_rptr_bin_q,

    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_wptr_gray_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_wptr_gray_d,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_wptr_bin_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_rptr_gray_q,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_rptr_gray_d,
    input wire  [FIFO_DEPTH_LOG2:0]         mon_resp_rptr_bin_q
);

    localparam int FIFO_DEPTH = 1 << FIFO_DEPTH_LOG2;
    localparam int PTR_W      = FIFO_DEPTH_LOG2 + 1;
    localparam int CNT_W      = FIFO_DEPTH_LOG2 + 3;
    localparam logic [1:0] ST_ACTIVE = 2'd3;

    // --------------------------------------------------------------------------
    // Stage A & Stage B Bounded Recovery / Deadlock-Freedom Trackers
    // --------------------------------------------------------------------------
    logic              f_wb_prev_q           = 1'b0;
    logic              f_slv_prev_q          = 1'b0;
    logic              f_rdc_saw_src_edge_q  = 1'b0;
    logic              f_rdc_saw_dst_edge_q  = 1'b0;
    logic [4:0]        f_calm_rounds_q       = 5'd0;

    logic              f_idle_saw_wb_edge_q  = 1'b0;
    logic              f_idle_saw_slv_edge_q = 1'b0;
    logic [4:0]        f_idle_rounds_q       = 5'd0;
    logic              f_fault_seen_q        = 1'b0;

    logic              f_slv_stalled_q       = 1'b0;
    logic              f_slv_we_prev_q       = 1'b0;
    logic [ADDR_W-1:0] f_slv_adr_prev_q      = '0;
    logic [DATA_W-1:0] f_slv_dat_prev_q      = '0;

    wire f_wb_posedge    = clk_fab_i && !f_wb_prev_q;
    wire f_slv_posedge   = clk_dll_i && !f_slv_prev_q;
    wire f_rdc_saw_both  = (f_rdc_saw_src_edge_q  || f_wb_posedge) && (f_rdc_saw_dst_edge_q  || f_slv_posedge);
    wire f_idle_saw_both = (f_idle_saw_wb_edge_q || f_wb_posedge) && (f_idle_saw_slv_edge_q || f_slv_posedge);

    always @($global_clock) begin
        f_wb_prev_q  <= clk_fab_i;
        f_slv_prev_q <= clk_dll_i;

        // Stage A calm round counter (cdc_reset_ctrlr)
        if ((f_step_q < 4'd4) || mon_rst_src_all || mon_rst_dst_all || mon_resp_timeout_q || mon_sw_rst_pend_q) begin
            f_rdc_saw_src_edge_q <= 1'b0;
            f_rdc_saw_dst_edge_q <= 1'b0;
            f_calm_rounds_q      <= 5'd0;
        end else if (f_rdc_saw_both) begin
            f_rdc_saw_src_edge_q <= 1'b0;
            f_rdc_saw_dst_edge_q <= 1'b0;
            if (f_calm_rounds_q != 5'd31) begin
                f_calm_rounds_q <= f_calm_rounds_q + 5'd1;
            end
        end else begin
            if (f_wb_posedge)  f_rdc_saw_src_edge_q <= 1'b1;
            if (f_slv_posedge) f_rdc_saw_dst_edge_q <= 1'b1;
        end

        // Stage B idle round counter (wb_b4_cdc)
        if (f_step_q < 4'd4) begin
            f_fault_seen_q <= 1'b0;
        end else if (mon_rst_wb || mon_rst_slv || mon_resp_timeout_q || (mon_discard_cnt != '0)) begin
            f_fault_seen_q <= 1'b1;
        end

        if ((f_step_q < 4'd4) || mon_rst_wb || mon_rst_slv || mon_isolate_wb || mon_isolate_slv || wb_cyc || wb_stb || mon_m_wb_stall) begin
            f_idle_saw_wb_edge_q  <= 1'b0;
            f_idle_saw_slv_edge_q <= 1'b0;
            f_idle_rounds_q       <= 5'd0;
        end else if (f_idle_saw_both) begin
            f_idle_saw_wb_edge_q  <= 1'b0;
            f_idle_saw_slv_edge_q <= 1'b0;
            if (f_idle_rounds_q != 5'd31) begin
                f_idle_rounds_q <= f_idle_rounds_q + 5'd1;
            end
        end else begin
            if (f_wb_posedge)  f_idle_saw_wb_edge_q  <= 1'b1;
            if (f_slv_posedge) f_idle_saw_slv_edge_q <= 1'b1;
        end
    end

    always_ff @(posedge clk_dll_i or posedge mon_rst_slv) begin
        if (mon_rst_slv) begin
            f_slv_stalled_q  <= 1'b0;
            f_slv_we_prev_q  <= 1'b0;
            f_slv_adr_prev_q <= '0;
            f_slv_dat_prev_q <= '0;
        end else if (mon_clr_slv || mon_isolate_slv) begin
            f_slv_stalled_q  <= 1'b0;
        end else begin
            f_slv_stalled_q  <= mon_m_wb_cyc && mon_m_wb_stb && mon_m_wb_stall;
            f_slv_we_prev_q  <= mon_m_wb_we;
            f_slv_adr_prev_q <= mon_m_wb_adr;
            f_slv_dat_prev_q <= mon_m_wb_dat;
        end
    end

    // FIFO Gray-code Hamming-distance next-state expressions
    wire [PTR_W-1:0] f_req_wptr_next  = mon_clr_wb  ? '0 : (mon_isolate_wb  ? mon_req_wptr_gray_q  : mon_req_wptr_gray_d);
    wire [PTR_W-1:0] f_req_wptr_diff  = f_req_wptr_next ^ mon_req_wptr_gray_q;
    wire [PTR_W-1:0] f_req_rptr_next  = mon_clr_slv ? '0 : (mon_isolate_slv ? mon_req_rptr_gray_q  : mon_req_rptr_gray_d);
    wire [PTR_W-1:0] f_req_rptr_diff  = f_req_rptr_next ^ mon_req_rptr_gray_q;

    wire [PTR_W-1:0] f_resp_wptr_next = mon_clr_slv ? '0 : (mon_isolate_slv ? mon_resp_wptr_gray_q : mon_resp_wptr_gray_d);
    wire [PTR_W-1:0] f_resp_wptr_diff = f_resp_wptr_next ^ mon_resp_wptr_gray_q;
    wire [PTR_W-1:0] f_resp_rptr_next = mon_clr_wb  ? '0 : (mon_isolate_wb  ? mon_resp_rptr_gray_q : mon_resp_rptr_gray_d);
    wire [PTR_W-1:0] f_resp_rptr_diff = f_resp_rptr_next ^ mon_resp_rptr_gray_q;

    always @($global_clock) begin
        if (f_step_q >= 4'd4) begin
            // 1. Freeze-Isolate-Then-Clear RDC Invariants (cdc_reset_ctrlr)
            if (mon_clr_wb) begin
                assert (mon_isolate_wb);
                assert (mon_isolate_slv);
            end
            if (mon_clr_slv) begin
                assert (mon_isolate_slv);
                assert (mon_isolate_wb);
            end

            // Stage A Bounded Post-Fault Recovery / Deadlock-Freedom Assertion
            if (!mon_rst_src_all && !mon_rst_dst_all && !mon_resp_timeout_q && !mon_sw_rst_pend_q && (f_calm_rounds_q >= 5'd16)) begin
                assert (mon_src_state_q == ST_ACTIVE);
                assert (mon_isolate_wb  == 1'b0);
                assert (mon_isolate_slv == 1'b0);
                assert (mon_clr_wb      == 1'b0);
                assert (mon_clr_slv     == 1'b0);
            end

            // 2. Request & Response Async FIFO Gray-Code & Occupancy Invariants
            if (!mon_isolate_slv) begin
                assert ((f_req_wptr_diff  & (f_req_wptr_diff  - 1'b1)) == '0);
                assert ((f_resp_rptr_diff & (f_resp_rptr_diff - 1'b1)) == '0);
            end
            if (!mon_isolate_wb) begin
                assert ((f_req_rptr_diff  & (f_req_rptr_diff  - 1'b1)) == '0);
                assert ((f_resp_wptr_diff & (f_resp_wptr_diff - 1'b1)) == '0);
            end
            if (!mon_isolate_wb && !mon_clr_wb) begin
                assert (mon_req_wptr_gray_q  == ((mon_req_wptr_bin_q  >> 1) ^ mon_req_wptr_bin_q));
                assert (mon_resp_rptr_gray_q == ((mon_resp_rptr_bin_q >> 1) ^ mon_resp_rptr_bin_q));
            end
            if (!mon_isolate_slv && !mon_clr_slv) begin
                assert (mon_req_rptr_gray_q  == ((mon_req_rptr_bin_q  >> 1) ^ mon_req_rptr_bin_q));
                assert (mon_resp_wptr_gray_q == ((mon_resp_wptr_bin_q >> 1) ^ mon_resp_wptr_bin_q));
            end
            if (!mon_isolate_wb && !mon_isolate_slv && !mon_clr_wb && !mon_clr_slv) begin
                assert (PTR_W'(mon_req_wptr_bin_q  - mon_req_rptr_bin_q)  <= PTR_W'(FIFO_DEPTH));
                assert (PTR_W'(mon_resp_wptr_bin_q - mon_resp_rptr_bin_q) <= PTR_W'(FIFO_DEPTH));
            end

            // 3. Internal Wishbone B4 & Counter Invariants (wb_b4_cdc)
            if (!mon_rst_wb) begin
                if (wb_ack) begin
                    assert (mon_outstanding_cnt > '0);
                end
                assert ((mon_outstanding_cnt + mon_discard_cnt) <= CNT_W'(2 * FIFO_DEPTH));
            end
            if (!mon_m_wb_cyc) begin
                assert (!mon_m_wb_stb);
            end
            if (!mon_rst_slv && !mon_clr_slv && !mon_isolate_slv) begin
                assert (mon_slv_inflight_cnt <= PTR_W'(FIFO_DEPTH));
                if (f_slv_stalled_q) begin
                    assert (mon_m_wb_cyc && mon_m_wb_stb);
                    assert (mon_m_wb_we  == f_slv_we_prev_q);
                    assert (mon_m_wb_adr == f_slv_adr_prev_q);
                    assert (mon_m_wb_dat == f_slv_dat_prev_q);
                end
            end

            // Stage B Bounded Post-Isolation Drain & Ready Assertion
            if (!mon_rst_wb && !mon_rst_slv && !mon_isolate_wb && !mon_isolate_slv &&
                !wb_cyc && !wb_stb && (f_idle_rounds_q >= 5'd6)) begin
                assert (mon_outstanding_cnt  == '0);
                assert (mon_discard_cnt      == '0);
                assert (mon_req_fifo_empty   == 1'b1);
                assert (mon_resp_fifo_empty  == 1'b1);
                assert (mon_slv_inflight_cnt == '0);
                assert (wb_stall             == 1'b0);
            end

            // White-box Reachability Covers
            cover ((f_calm_rounds_q == 5'd16) && (mon_src_state_q == ST_ACTIVE));
            cover ((f_idle_rounds_q == 5'd6) && !wb_stall);
            cover (f_fault_seen_q && !mon_isolate_wb && !mon_isolate_slv && !wb_stall && wb_ack);
        end
    end

endmodule

module formal_wbb4_cdc #(
    parameter int FIFO_DEPTH_LOG2 = 2
) (
    input wire clk_fab_i,
    input wire clk_dll_i,
    input wire rst_fab_i,
    input wire rst_dll_pad_i
);

    localparam int ADDR_W              = 2;
    localparam int DATA_W              = 4;
    localparam int FIFO_DEPTH          = 1 << FIFO_DEPTH_LOG2;
    localparam int PTR_W               = FIFO_DEPTH_LOG2 + 1;
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

    // Instantiated white-box checker (mon_* ports connected post-flatten in Yosys)
    formal_wbb4_cdc_whitebox #(
        .ADDR_W          (ADDR_W),
        .DATA_W          (DATA_W),
        .FIFO_DEPTH_LOG2 (FIFO_DEPTH_LOG2)
    ) u_whitebox (
        .clk_fab_i            (clk_fab_i),
        .clk_dll_i            (clk_dll_i),
        .f_step_q             (f_step_q),
        .wb_cyc               (wb_cyc),
        .wb_stb               (wb_stb),
        .wb_stall             (wb_stall),
        .wb_ack               (wb_ack),
        .mon_rst_src_all      (1'b0),
        .mon_rst_dst_all      (1'b0),
        .mon_sw_rst_pend_q    (1'b0),
        .mon_src_state_q      (2'b0),
        .mon_rst_wb           (1'b0),
        .mon_rst_slv          (1'b0),
        .mon_isolate_wb       (1'b0),
        .mon_isolate_slv      (1'b0),
        .mon_clr_wb           (1'b0),
        .mon_clr_slv          (1'b0),
        .mon_resp_timeout_q   (1'b0),
        .mon_outstanding_cnt  ('0),
        .mon_discard_cnt      ('0),
        .mon_slv_inflight_cnt ('0),
        .mon_req_fifo_empty   (1'b0),
        .mon_resp_fifo_empty  (1'b0),
        .mon_m_wb_cyc         (1'b0),
        .mon_m_wb_stb         (1'b0),
        .mon_m_wb_we          (1'b0),
        .mon_m_wb_adr         ('0),
        .mon_m_wb_dat         ('0),
        .mon_m_wb_stall       (1'b0),
        .mon_req_wptr_gray_q  ('0),
        .mon_req_wptr_gray_d  ('0),
        .mon_req_wptr_bin_q   ('0),
        .mon_req_rptr_gray_q  ('0),
        .mon_req_rptr_gray_d  ('0),
        .mon_req_rptr_bin_q   ('0),
        .mon_resp_wptr_gray_q ('0),
        .mon_resp_wptr_gray_d ('0),
        .mon_resp_wptr_bin_q  ('0),
        .mon_resp_rptr_gray_q ('0),
        .mon_resp_rptr_gray_d ('0),
        .mon_resp_rptr_bin_q  ('0)
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

// ==============================================================================
// Unbounded Temporal k-Induction Harness (t -> infinity)
// Proves FSM legality, RDC isolation guarantees, Gray-code single-bit pointer
// transitions, and Wishbone B4 protocol mutual exclusion for all time.
// ==============================================================================
(* keep_hierarchy = "yes" *)
module formal_wbb4_cdc_induct_wb #(
    parameter int PTR_W = 4
) (
    input wire             f_past_valid_i,
    input wire             rst_wb_i,
    input wire             rst_slv_i,
    input wire             s_wb_cyc_i,
    input wire             s_wb_ack_i,
    input wire             s_wb_err_i,
    input wire             m_wb_cyc_i,
    input wire             m_wb_stb_i,
    input wire             mon_rst_src_all,
    input wire             mon_rst_dst_all,
    input wire [1:0]       mon_src_state_q,
    input wire             mon_dst_evt_n_q,
    input wire             mon_isolate_wb,
    input wire             mon_isolate_slv,
    input wire             mon_clr_wb,
    input wire             mon_clr_slv,
    input wire [PTR_W-1:0] mon_req_wptr_gray_q,
    input wire [PTR_W-1:0] mon_req_wptr_gray_d,
    input wire [PTR_W-1:0] mon_req_wptr_bin_q,
    input wire [PTR_W-1:0] mon_req_rptr_gray_q,
    input wire [PTR_W-1:0] mon_req_rptr_gray_d,
    input wire [PTR_W-1:0] mon_req_rptr_bin_q,
    input wire [PTR_W-1:0] mon_resp_wptr_gray_q,
    input wire [PTR_W-1:0] mon_resp_wptr_gray_d,
    input wire [PTR_W-1:0] mon_resp_wptr_bin_q,
    input wire [PTR_W-1:0] mon_resp_rptr_gray_q,
    input wire [PTR_W-1:0] mon_resp_rptr_gray_d,
    input wire [PTR_W-1:0] mon_resp_rptr_bin_q
);

    always @($global_clock) begin
        if (f_past_valid_i) begin
            // 1. cdc_reset_ctrlr Freeze-Isolate-Then-Clear & isolation invariants
            if (mon_rst_src_all) begin
                assert (mon_isolate_wb);
                assert (!mon_clr_wb);
            end
            if (mon_src_state_q != 2'd3) begin
                assert (mon_isolate_wb);
            end
            if (mon_rst_dst_all) begin
                assert (mon_isolate_slv);
                assert (!mon_clr_slv);
            end
            if (!mon_dst_evt_n_q) begin
                assert (mon_isolate_slv);
            end
            if (mon_clr_wb) begin
                assert (mon_isolate_wb);
            end
            if (mon_clr_slv) begin
                assert (mon_isolate_slv);
            end

            // 2. cdc_fifo_gray_clearable binary-to-Gray state & single-bit transition invariants
            // Proven inductive without power-on FF initializers because exiting ST_REQ_HIGH (2'd0)
            // or setting dst_evt_n_q=1 structurally forces clr_wb / clr_slv first.
            if (!mon_rst_src_all && (mon_src_state_q != 2'd0)) begin
                assert (mon_req_wptr_gray_q  == (mon_req_wptr_bin_q  ^ (mon_req_wptr_bin_q  >> 1)));
                assert (mon_resp_rptr_gray_q == (mon_resp_rptr_bin_q ^ (mon_resp_rptr_bin_q >> 1)));
                if (!mon_clr_wb) begin
                    assert ($countones(mon_req_wptr_gray_d  ^ mon_req_wptr_gray_q)  <= 1);
                    assert ($countones(mon_resp_rptr_gray_d ^ mon_resp_rptr_gray_q) <= 1);
                end
            end

            if (!mon_rst_dst_all && mon_dst_evt_n_q) begin
                assert (mon_req_rptr_gray_q  == (mon_req_rptr_bin_q  ^ (mon_req_rptr_bin_q  >> 1)));
                assert (mon_resp_wptr_gray_q == (mon_resp_wptr_bin_q ^ (mon_resp_wptr_bin_q >> 1)));
                if (!mon_clr_slv) begin
                    assert ($countones(mon_req_rptr_gray_d  ^ mon_req_rptr_gray_q)  <= 1);
                    assert ($countones(mon_resp_wptr_gray_d ^ mon_resp_wptr_gray_q) <= 1);
                end
            end

            // 3. wb_b4_cdc Wishbone B4 protocol & isolation safety invariants
            assert (!(s_wb_ack_i && s_wb_err_i));
            if (!s_wb_cyc_i) begin
                assert (!s_wb_ack_i && !s_wb_err_i);
            end
            if (m_wb_stb_i) begin
                assert (m_wb_cyc_i);
            end
            if (mon_isolate_slv) begin
                assert (!m_wb_cyc_i && !m_wb_stb_i);
            end
        end
    end

endmodule

module formal_wbb4_cdc_induct (
    input wire       clk_wb_i,
    input wire       rst_wb_i,
    input wire       s_wb_cyc_i,
    input wire       s_wb_stb_i,
    input wire       s_wb_we_i,
    input wire [1:0] s_wb_adr_i,
    input wire [3:0] s_wb_dat_i,
    input wire       clk_slv_i,
    input wire       rst_slv_i,
    input wire       m_wb_stall_i,
    input wire       m_wb_ack_i,
    input wire       m_wb_err_i,
    input wire [3:0] m_wb_dat_i
);

    localparam int FIFO_DEPTH_LOG2 = 2;
    localparam int PTR_W           = FIFO_DEPTH_LOG2 + 1;

    logic [1:0] f_boot_q = 2'd0;
    always @($global_clock) begin
        if (f_boot_q != 2'd2) begin
            f_boot_q <= f_boot_q + 2'd1;
        end
    end
    always @($global_clock) begin
        if (f_boot_q < 2'd2) begin
            assume (rst_wb_i  == 1'b1);
            assume (rst_slv_i == 1'b1);
            assume (clk_wb_i  == 1'b0);
            assume (clk_slv_i == 1'b0);
        end
    end

    wire       s_wb_stall;
    wire       s_wb_ack;
    wire       s_wb_err;
    wire [3:0] s_wb_dat_o;
    wire       m_wb_cyc;
    wire       m_wb_stb;
    wire       m_wb_we;
    wire [1:0] m_wb_adr;
    wire [3:0] m_wb_dat_o;

    wb_b4_cdc #(
        .ADDR_W              (2),
        .DATA_W              (4),
        .FIFO_DEPTH_LOG2     (FIFO_DEPTH_LOG2),
        .SYNC_STAGES         (2),
        .EN_GATE_TIMEOUT     (1),
        .GATE_TIMEOUT_CYCLES (8),
        .EN_RESP_TIMEOUT     (1),
        .RESP_TIMEOUT_CYCLES (8)
    ) u_dut (
        .clk_wb_i     (clk_wb_i),
        .rst_wb_i     (rst_wb_i),
        .s_wb_cyc_i   (s_wb_cyc_i),
        .s_wb_stb_i   (s_wb_stb_i),
        .s_wb_we_i    (s_wb_we_i),
        .s_wb_adr_i   (s_wb_adr_i),
        .s_wb_dat_i   (s_wb_dat_i),
        .s_wb_stall_o (s_wb_stall),
        .s_wb_ack_o   (s_wb_ack),
        .s_wb_err_o   (s_wb_err),
        .s_wb_dat_o   (s_wb_dat_o),

        .clk_slv_i    (clk_slv_i),
        .rst_slv_i    (rst_slv_i),
        .m_wb_cyc_o   (m_wb_cyc),
        .m_wb_stb_o   (m_wb_stb),
        .m_wb_we_o    (m_wb_we),
        .m_wb_adr_o   (m_wb_adr),
        .m_wb_dat_o   (m_wb_dat_o),
        .m_wb_stall_i (m_wb_stall_i),
        .m_wb_ack_i   (m_wb_ack_i),
        .m_wb_err_i   (m_wb_err_i),
        .m_wb_dat_i   (m_wb_dat_i)
    );

    formal_wbb4_cdc_induct_wb #(
        .PTR_W (PTR_W)
    ) u_induct_wb (
        .f_past_valid_i       (f_boot_q == 2'd2),
        .rst_wb_i             (rst_wb_i),
        .rst_slv_i            (rst_slv_i),
        .s_wb_cyc_i           (s_wb_cyc_i),
        .s_wb_ack_i           (s_wb_ack),
        .s_wb_err_i           (s_wb_err),
        .m_wb_cyc_i           (m_wb_cyc),
        .m_wb_stb_i           (m_wb_stb),
        .mon_rst_src_all      (1'b0),
        .mon_rst_dst_all      (1'b0),
        .mon_src_state_q      (2'b0),
        .mon_dst_evt_n_q      (1'b0),
        .mon_isolate_wb       (1'b0),
        .mon_isolate_slv      (1'b0),
        .mon_clr_wb           (1'b0),
        .mon_clr_slv          (1'b0),
        .mon_req_wptr_gray_q  ('0),
        .mon_req_wptr_gray_d  ('0),
        .mon_req_wptr_bin_q   ('0),
        .mon_req_rptr_gray_q  ('0),
        .mon_req_rptr_gray_d  ('0),
        .mon_req_rptr_bin_q   ('0),
        .mon_resp_wptr_gray_q ('0),
        .mon_resp_wptr_gray_d ('0),
        .mon_resp_wptr_bin_q  ('0),
        .mon_resp_rptr_gray_q ('0),
        .mon_resp_rptr_gray_d ('0),
        .mon_resp_rptr_bin_q  ('0)
    );

endmodule

`default_nettype wire
