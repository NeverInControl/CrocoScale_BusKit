// ==============================================================================
// Module: wb_b4_cdc
// Description:
//   Reusable Full-Bandwidth Wishbone B4 Pipelined Clock Domain Crossing (CDC)
//   and Reset Domain Crossing (RDC) Bridge.
// ==============================================================================

`default_nettype none

module wb_b4_cdc #(
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
    // Upstream Wishbone B4 Pipelined Slave Port (Master / Fabric Clock Domain)
    // --------------------------------------------------------------------------
    input  wire               clk_wb_i,
    input  wire               rst_wb_i,      // AASD reset in clk_wb_i
    input  wire               s_wb_cyc_i,
    input  wire               s_wb_stb_i,
    input  wire               s_wb_we_i,
    input  wire  [ADDR_W-1:0] s_wb_adr_i,
    input  wire  [DATA_W-1:0] s_wb_dat_i,
    output logic              s_wb_stall_o,
    output logic              s_wb_ack_o,
    output logic              s_wb_err_o,
    output logic [DATA_W-1:0] s_wb_dat_o,

    // --------------------------------------------------------------------------
    // Downstream Wishbone B4 Pipelined Master Port (Slave / DLL Clock Domain)
    // --------------------------------------------------------------------------
    input  wire               clk_slv_i,
    input  wire               rst_slv_i,     // AASD reset in clk_slv_i
    output logic              m_wb_cyc_o,
    output logic              m_wb_stb_o,
    output logic              m_wb_we_o,
    output logic [ADDR_W-1:0] m_wb_adr_o,
    output logic [DATA_W-1:0] m_wb_dat_o,
    input  wire               m_wb_stall_i,
    input  wire               m_wb_ack_i,
    input  wire               m_wb_err_i,
    input  wire  [DATA_W-1:0] m_wb_dat_i
);

    localparam int FIFO_DEPTH  = 1 << FIFO_DEPTH_LOG2;
    localparam int PTR_W       = FIFO_DEPTH_LOG2 + 1;
    localparam int CNT_W       = FIFO_DEPTH_LOG2 + 3;
    localparam int REQ_PAY_W   = 1 + ADDR_W + DATA_W;
    localparam int RESP_PAY_W  = 1 + DATA_W;

    localparam int GATE_WDOG_W = (GATE_TIMEOUT_CYCLES > 1) ? $clog2(GATE_TIMEOUT_CYCLES) : 1;
    localparam int RESP_WDOG_W = (RESP_TIMEOUT_CYCLES > 1) ? $clog2(RESP_TIMEOUT_CYCLES) : 1;

    // --------------------------------------------------------------------------
    // Cross-Domain Reset & RDC Isolation Controller
    // --------------------------------------------------------------------------
    logic isolate_wb,  clr_wb;
    logic isolate_slv, clr_slv;
    logic resp_timeout_fire_q;

    cdc_reset_ctrlr #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_reset_ctrlr (
        .clk_src_i        (clk_wb_i),
        .rst_src_i        (rst_wb_i),
        .sw_rst_req_src_i (resp_timeout_fire_q),
        .isolate_src_o    (isolate_wb),
        .clr_src_o        (clr_wb),

        .clk_dst_i        (clk_slv_i),
        .rst_dst_i        (rst_slv_i),
        .isolate_dst_o    (isolate_slv),
        .clr_dst_o        (clr_slv)
    );

    // --------------------------------------------------------------------------
    // Upstream (clk_wb_i) B4 Protocol Isolator, Burst Tracker & Watchdogs
    // --------------------------------------------------------------------------
    logic [CNT_W-1:0]       outstanding_cnt_q;
    logic [CNT_W-1:0]       discard_cnt_q;
    logic                   err_drain_mode_q;

    logic                   req_fifo_wr_en;
    logic [REQ_PAY_W-1:0]   req_fifo_wdata;
    logic                   req_fifo_full;
    logic [PTR_W-1:0]       req_fifo_used_wr;

    logic                   resp_fifo_rd_en;
    logic [RESP_PAY_W-1:0]  resp_fifo_rdata;
    logic                   resp_fifo_empty;

    wire                    resp_fifo_err = resp_fifo_rdata[DATA_W];
    wire  [DATA_W-1:0]      resp_fifo_dat = resp_fifo_rdata[DATA_W-1:0];

    wire  cnt_limit_reached = ((outstanding_cnt_q + discard_cnt_q) >= CNT_W'(2 * FIFO_DEPTH));

    logic [GATE_WDOG_W-1:0] gate_wdog_cnt_q;
    logic                   gate_timeout_fire_q;
    logic [RESP_WDOG_W-1:0] resp_wdog_cnt_q;

    wire  gate_normal_open  = !isolate_wb && !clr_wb && !err_drain_mode_q && !req_fifo_full && !cnt_limit_reached;
    assign s_wb_stall_o     = !(gate_normal_open || gate_timeout_fire_q);

    wire  req_accepted      = s_wb_cyc_i && s_wb_stb_i && !s_wb_stall_o;
    assign req_fifo_wr_en   = req_accepted && !gate_timeout_fire_q;
    assign req_fifo_wdata   = {s_wb_we_i, s_wb_adr_i, s_wb_dat_i};

    wire  resp_discarded    = !isolate_wb && !clr_wb && !resp_fifo_empty && (discard_cnt_q != '0);
    wire  resp_valid_norm   = !isolate_wb && !clr_wb && !err_drain_mode_q && !resp_fifo_empty &&
                              (discard_cnt_q == '0) && (outstanding_cnt_q != '0);

    wire  resp_deliver_norm = s_wb_cyc_i && resp_valid_norm;
    wire  resp_deliver_err  = s_wb_cyc_i && err_drain_mode_q && (outstanding_cnt_q != '0);
    wire  resp_delivered    = resp_deliver_norm || resp_deliver_err;

    assign resp_fifo_rd_en  = resp_discarded || resp_deliver_norm;

    assign s_wb_ack_o       = resp_deliver_norm && !resp_fifo_err;
    assign s_wb_err_o       = (resp_deliver_norm && resp_fifo_err) || resp_deliver_err;
    assign s_wb_dat_o       = resp_deliver_norm ? resp_fifo_dat : '0;

    // Registered In-Flight Response Watchdog Timer
    always_ff @(posedge clk_wb_i or posedge rst_wb_i) begin
        if (rst_wb_i) begin
            resp_wdog_cnt_q     <= '0;
            resp_timeout_fire_q <= 1'b0;
        end else begin
            resp_timeout_fire_q <= 1'b0;
            if (isolate_wb || err_drain_mode_q || ((outstanding_cnt_q == '0) && (discard_cnt_q == '0)) || resp_fifo_rd_en) begin
                resp_wdog_cnt_q <= '0;
            end else if (EN_RESP_TIMEOUT != 0) begin
                if (resp_wdog_cnt_q == RESP_WDOG_W'(RESP_TIMEOUT_CYCLES - 1)) begin
                    resp_wdog_cnt_q     <= '0;
                    resp_timeout_fire_q <= 1'b1;
                end else begin
                    resp_wdog_cnt_q     <= resp_wdog_cnt_q + 1'b1;
                end
            end
        end
    end

    // Registered Wait-at-the-Gates Watchdog Timer
    always_ff @(posedge clk_wb_i or posedge rst_wb_i) begin
        if (rst_wb_i) begin
            gate_wdog_cnt_q     <= '0;
            gate_timeout_fire_q <= 1'b0;
        end else begin
            gate_timeout_fire_q <= 1'b0;
            if ((EN_GATE_TIMEOUT != 0) && s_wb_cyc_i && s_wb_stb_i && s_wb_stall_o &&
                !err_drain_mode_q && (outstanding_cnt_q == '0)) begin
                if (gate_wdog_cnt_q == GATE_WDOG_W'(GATE_TIMEOUT_CYCLES - 1)) begin
                    gate_wdog_cnt_q     <= '0;
                    gate_timeout_fire_q <= 1'b1;
                end else begin
                    gate_wdog_cnt_q     <= gate_wdog_cnt_q + 1'b1;
                end
            end else begin
                gate_wdog_cnt_q <= '0;
            end
        end
    end

    // Burst Outstanding & Aborted-Discard Counter Management
    always_ff @(posedge clk_wb_i or posedge rst_wb_i) begin
        if (rst_wb_i) begin
            outstanding_cnt_q <= '0;
            discard_cnt_q     <= '0;
            err_drain_mode_q  <= 1'b0;
        end else begin
            if (isolate_wb || clr_wb || resp_timeout_fire_q) begin
                discard_cnt_q <= '0;
            end else if (!s_wb_cyc_i && !err_drain_mode_q && (outstanding_cnt_q != '0)) begin
                discard_cnt_q <= discard_cnt_q + outstanding_cnt_q - (resp_discarded ? 1'b1 : 1'b0);
            end else if (resp_discarded) begin
                discard_cnt_q <= discard_cnt_q - 1'b1;
            end

            if (!s_wb_cyc_i) begin
                outstanding_cnt_q <= '0;
                err_drain_mode_q  <= 1'b0;
            end else begin
                if (req_accepted && !resp_delivered) begin
                    outstanding_cnt_q <= outstanding_cnt_q + 1'b1;
                end else if (!req_accepted && resp_delivered) begin
                    outstanding_cnt_q <= outstanding_cnt_q - 1'b1;
                end

                if (req_accepted && gate_timeout_fire_q) begin
                    err_drain_mode_q <= 1'b1;
                end else if ((isolate_wb || resp_timeout_fire_q) && (outstanding_cnt_q != '0)) begin
                    if (!(resp_deliver_norm && (outstanding_cnt_q == CNT_W'(1)))) begin
                        err_drain_mode_q <= 1'b1;
                    end
                end else if (err_drain_mode_q && resp_deliver_err && (outstanding_cnt_q == CNT_W'(1))) begin
                    err_drain_mode_q <= 1'b0;
                end
            end
        end
    end

    // --------------------------------------------------------------------------
    // Request Async FIFO (clk_wb_i -> clk_slv_i)
    // --------------------------------------------------------------------------
    logic                 req_fifo_rd_en;
    logic [REQ_PAY_W-1:0] req_fifo_rdata;
    logic                 req_fifo_empty;

    cdc_fifo_gray_clearable #(
        .DATA_W      (REQ_PAY_W),
        .DEPTH_LOG2  (FIFO_DEPTH_LOG2),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_req_fifo (
        .clk_wr_i          (clk_wb_i),
        .rst_wr_i          (rst_wb_i),
        .clr_wr_i          (clr_wb),
        .isolate_wr_i      (isolate_wb),
        .wr_en_i           (req_fifo_wr_en),
        .wr_data_i         (req_fifo_wdata),
        .full_o            (req_fifo_full),
        .used_entries_wr_o (req_fifo_used_wr),

        .clk_rd_i          (clk_slv_i),
        .rst_rd_i          (rst_slv_i),
        .clr_rd_i          (clr_slv),
        .isolate_rd_i      (isolate_slv),
        .rd_en_i           (req_fifo_rd_en),
        .rd_data_o         (req_fifo_rdata),
        .empty_o           (req_fifo_empty)
    );

    // --------------------------------------------------------------------------
    // Downstream (clk_slv_i) Wishbone B4 Master Engine with Entry Reservation
    // --------------------------------------------------------------------------
    logic                  resp_fifo_wr_en;
    logic [RESP_PAY_W-1:0] resp_fifo_wdata;
    logic                  resp_fifo_full;
    logic [PTR_W-1:0]      resp_fifo_used_wr;

    logic [PTR_W-1:0]      slv_inflight_cnt_q;

    wire  resp_entry_avail = !isolate_slv && !clr_slv && !resp_fifo_full &&
                             ((resp_fifo_used_wr + slv_inflight_cnt_q) < PTR_W'(FIFO_DEPTH));

    assign m_wb_stb_o      = !isolate_slv && !clr_slv && !req_fifo_empty && resp_entry_avail;
    assign m_wb_cyc_o      = !isolate_slv && !clr_slv && (!req_fifo_empty || (slv_inflight_cnt_q != '0));
    assign {m_wb_we_o, m_wb_adr_o, m_wb_dat_o} = m_wb_stb_o ? req_fifo_rdata : '0;

    wire  slv_req_issued   = m_wb_cyc_o && m_wb_stb_o && !m_wb_stall_i;
    wire  slv_resp_rcvd    = m_wb_cyc_o && (m_wb_ack_i || m_wb_err_i) && (slv_inflight_cnt_q != '0);

    assign req_fifo_rd_en  = slv_req_issued;
    assign resp_fifo_wr_en = slv_resp_rcvd;
    assign resp_fifo_wdata = {m_wb_err_i, m_wb_dat_i};

    always_ff @(posedge clk_slv_i or posedge rst_slv_i) begin
        if (rst_slv_i) begin
            slv_inflight_cnt_q <= '0;
        end else if (isolate_slv || clr_slv) begin
            slv_inflight_cnt_q <= '0;
        end else begin
            if (slv_req_issued && !slv_resp_rcvd) begin
                slv_inflight_cnt_q <= slv_inflight_cnt_q + 1'b1;
            end else if (!slv_req_issued && slv_resp_rcvd) begin
                slv_inflight_cnt_q <= slv_inflight_cnt_q - 1'b1;
            end
        end
    end

    // --------------------------------------------------------------------------
    // Response Async FIFO (clk_slv_i -> clk_wb_i)
    // --------------------------------------------------------------------------
    cdc_fifo_gray_clearable #(
        .DATA_W      (RESP_PAY_W),
        .DEPTH_LOG2  (FIFO_DEPTH_LOG2),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_resp_fifo (
        .clk_wr_i          (clk_slv_i),
        .rst_wr_i          (rst_slv_i),
        .clr_wr_i          (clr_slv),
        .isolate_wr_i      (isolate_slv),
        .wr_en_i           (resp_fifo_wr_en),
        .wr_data_i         (resp_fifo_wdata),
        .full_o            (resp_fifo_full),
        .used_entries_wr_o (resp_fifo_used_wr),

        .clk_rd_i          (clk_wb_i),
        .rst_rd_i          (rst_wb_i),
        .clr_rd_i          (clr_wb),
        .isolate_rd_i      (isolate_wb),
        .rd_en_i           (resp_fifo_rd_en),
        .rd_data_o         (resp_fifo_rdata),
        .empty_o           (resp_fifo_empty)
    );

endmodule

`default_nettype wire

