// ==============================================================================
// Module: cdc_reset_ctrlr
// Description:
//   Four-phase cross-domain reset and RDC isolation controller implementing
//   strict Freeze-Isolate-Then-Clear ordering across independent clock and
//   AASD reset domains (clk_src_i / rst_src_i and clk_dst_i / rst_dst_i).
//   All asynchronously reset registers reset to 0 for direct mapping to
//   IHP 130nm sg13cmos5l_dfrbpq_1 standard cells.
// ==============================================================================

`default_nettype none

module cdc_reset_ctrlr #(
    parameter int SYNC_STAGES = 2
) (
    // Source / Master Clock Domain
    input  wire  clk_src_i,
    input  wire  rst_src_i,
    input  wire  sw_rst_req_src_i,
    output logic isolate_src_o,
    output logic clr_src_o,

    // Destination / Slave Clock Domain
    input  wire  clk_dst_i,
    input  wire  rst_dst_i,
    output logic isolate_dst_o,
    output logic clr_dst_o
);

    // --------------------------------------------------------------------------
    // Cross-Domain AASD Reset Event Bridges
    // --------------------------------------------------------------------------
    // Guarantee that an asynchronous reset pulse in either domain immediately
    // isolates and resets the partner domain's handshake state and synchronizers,
    // regardless of relative clock frequencies or stopped clocks.
    logic dst_rst_in_src;
    logic src_rst_in_dst;

    rst_sync_aasd #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_dst_rst_to_src (
        .clk_i       (clk_src_i),
        .rst_async_i (rst_dst_i),
        .rst_sync_o  (dst_rst_in_src)
    );

    rst_sync_aasd #(
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_src_rst_to_dst (
        .clk_i       (clk_dst_i),
        .rst_async_i (rst_src_i || sw_rst_req_src_i),
        .rst_sync_o  (src_rst_in_dst)
    );

    wire rst_src_all = rst_src_i || dst_rst_in_src;
    wire rst_dst_all = rst_dst_i || src_rst_in_dst;

    // --------------------------------------------------------------------------
    // Destination Domain: Post-Reset Isolation Latch & 4-Phase Responder
    // --------------------------------------------------------------------------
    // Stored inverted (dst_evt_n_q resets to 0) to map directly to dfrbpq_1 cells.
    logic dst_evt_n_q;
    logic dst_ack_q;
    logic src_req_in_dst;

    wire  dst_evt = ~dst_evt_n_q;

    always_ff @(posedge clk_dst_i or posedge rst_dst_all) begin
        if (rst_dst_all) begin
            dst_evt_n_q <= 1'b0;
            dst_ack_q   <= 1'b0;
        end else begin
            if (src_req_in_dst) begin
                dst_evt_n_q <= 1'b1;
            end
            dst_ack_q <= src_req_in_dst;
        end
    end

    assign isolate_dst_o = rst_dst_all || dst_evt || src_req_in_dst || dst_ack_q;
    assign clr_dst_o     = src_req_in_dst;

    // --------------------------------------------------------------------------
    // Source Domain: 4-Phase Coordinator State Machine
    // --------------------------------------------------------------------------
    localparam logic [1:0] ST_REQ_HIGH     = 2'd0;
    localparam logic [1:0] ST_CLR_HOLD     = 2'd1;
    localparam logic [1:0] ST_WAIT_ACK_LOW = 2'd2;
    localparam logic [1:0] ST_ACTIVE       = 2'd3;

    (* fsm_encoding = "none" *)
    logic [1:0] src_state_q;
    logic       src_req_n_q;
    logic       sw_rst_pend_q;

    wire        src_req = ~src_req_n_q;
    logic       dst_ack_in_src;

    always_ff @(posedge clk_src_i or posedge rst_src_all) begin
        if (rst_src_all) begin
            src_state_q   <= ST_REQ_HIGH;
            src_req_n_q   <= 1'b0;
            sw_rst_pend_q <= 1'b0;
        end else begin
            if (sw_rst_req_src_i && ((src_state_q == ST_CLR_HOLD) || (src_state_q == ST_WAIT_ACK_LOW))) begin
                sw_rst_pend_q <= 1'b1;
            end

            case (src_state_q)
                ST_REQ_HIGH: begin
                    src_req_n_q   <= 1'b0;
                    sw_rst_pend_q <= 1'b0;
                    if (dst_ack_in_src && !sw_rst_req_src_i) begin
                        src_state_q <= ST_CLR_HOLD;
                    end
                end

                ST_CLR_HOLD: begin
                    src_req_n_q <= 1'b1;
                    src_state_q <= ST_WAIT_ACK_LOW;
                end

                ST_WAIT_ACK_LOW: begin
                    src_req_n_q <= 1'b1;
                    if (!dst_ack_in_src) begin
                        if (sw_rst_req_src_i || sw_rst_pend_q) begin
                            src_req_n_q   <= 1'b0;
                            sw_rst_pend_q <= 1'b0;
                            src_state_q   <= ST_REQ_HIGH;
                        end else begin
                            src_state_q   <= ST_ACTIVE;
                        end
                    end
                end

                ST_ACTIVE: begin
                    src_req_n_q <= 1'b1;
                    if (sw_rst_req_src_i) begin
                        src_req_n_q <= 1'b0;
                        src_state_q <= ST_REQ_HIGH;
                    end
                end

                default: begin
                    src_req_n_q <= 1'b0;
                    src_state_q <= ST_REQ_HIGH;
                end
            endcase
        end
    end

    assign isolate_src_o = rst_src_all || (src_state_q != ST_ACTIVE);
    assign clr_src_o     = (src_state_q == ST_REQ_HIGH) && dst_ack_in_src;

    // --------------------------------------------------------------------------
    // Cross-Domain 2-FF Synchronizers
    // --------------------------------------------------------------------------
    cdc_sync_2ff #(
        .WIDTH       (1),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_src_req_to_dst (
        .clk_i (clk_dst_i),
        .rst_i (rst_dst_all),
        .d_i   (src_req),
        .q_o   (src_req_in_dst)
    );

    cdc_sync_2ff #(
        .WIDTH       (1),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_sync_dst_ack_to_src (
        .clk_i (clk_src_i),
        .rst_i (rst_src_all),
        .d_i   (dst_ack_q),
        .q_o   (dst_ack_in_src)
    );

`ifdef FORMAL
    logic [3:0] f_step_q         = 4'd0;
    logic       f_src_prev_q     = 1'b0;
    logic       f_dst_prev_q     = 1'b0;
    logic       f_saw_src_edge_q = 1'b0;
    logic       f_saw_dst_edge_q = 1'b0;
    logic [4:0] f_calm_rounds_q  = 5'd0;

    wire f_src_posedge = clk_src_i && !f_src_prev_q;
    wire f_dst_posedge = clk_dst_i && !f_dst_prev_q;
    wire f_saw_both    = (f_saw_src_edge_q || f_src_posedge) && (f_saw_dst_edge_q || f_dst_posedge);

    always @($global_clock) begin
        if (f_step_q != 4'hF) begin
            f_step_q <= f_step_q + 4'd1;
        end
        f_src_prev_q <= clk_src_i;
        f_dst_prev_q <= clk_dst_i;

        if ((f_step_q < 4'd4) || rst_src_all || rst_dst_all || sw_rst_req_src_i || sw_rst_pend_q) begin
            f_saw_src_edge_q <= 1'b0;
            f_saw_dst_edge_q <= 1'b0;
            f_calm_rounds_q  <= 5'd0;
        end else if (f_saw_both) begin
            f_saw_src_edge_q <= 1'b0;
            f_saw_dst_edge_q <= 1'b0;
            if (f_calm_rounds_q != 5'd31) begin
                f_calm_rounds_q <= f_calm_rounds_q + 5'd1;
            end
        end else begin
            if (f_src_posedge) f_saw_src_edge_q <= 1'b1;
            if (f_dst_posedge) f_saw_dst_edge_q <= 1'b1;
        end
    end

    always @($global_clock) begin
        if (f_step_q >= 4'd4) begin
            if (clr_src_o) begin
                assert (isolate_src_o);
                assert (isolate_dst_o);
            end
            if (clr_dst_o) begin
                assert (isolate_dst_o);
                assert (isolate_src_o);
            end
            // Stage A Bounded Post-Fault Recovery / Deadlock-Freedom Assertion
            if (!rst_src_all && !rst_dst_all && !sw_rst_req_src_i && !sw_rst_pend_q && (f_calm_rounds_q >= 5'd16)) begin
                assert (src_state_q   == ST_ACTIVE);
                assert (isolate_src_o == 1'b0);
                assert (isolate_dst_o == 1'b0);
                assert (clr_src_o     == 1'b0);
                assert (clr_dst_o     == 1'b0);
            end
            cover ((f_calm_rounds_q == 5'd16) && (src_state_q == ST_ACTIVE));
        end
    end
`endif

endmodule

`default_nettype wire
