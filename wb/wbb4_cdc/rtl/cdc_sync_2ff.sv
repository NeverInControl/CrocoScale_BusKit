// ==============================================================================
// Module: cdc_sync_2ff
// Description:
//   Parameterized multi-stage flip-flop synchronizer for Clock Domain Crossing.
//   Uses a packed shift vector (mapped directly to sg13cmos5l_dfrbp_1 cells in
//   IHP 130nm without memory-array inference warnings) and supports physical
//   setup-window metastability skew injection under SIM_CDC_JITTER.
// ==============================================================================

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module cdc_sync_2ff #(
    parameter int WIDTH       = 1,
    parameter int SYNC_STAGES = 2
) (
    input  wire              clk_i,
    input  wire              rst_i,
    input  wire  [WIDTH-1:0] d_i,
    output logic [WIDTH-1:0] q_o
);

    // Stage 0 (metastable capture flop) is named distinctly from Stage 1..N
    // (sync_pipe_q) so LibreLane / OpenSTA SDC constraints and GLS skew models
    // can target *sync_meta_q* without false-pathing the Stage 0 -> Stage 1 path.
    (* keep = "true", async_reg = "true", dont_touch = "true" *)
    logic [WIDTH-1:0]               sync_meta_q;

    (* keep = "true", async_reg = "true", dont_touch = "true" *)
    logic [(SYNC_STAGES-1)*WIDTH-1:0] sync_pipe_q;

`ifdef SIM_CDC_JITTER
    localparam real   SETUP_APERTURE_NS = 2.0;
    real              last_chg_t [0:WIDTH-1];
    logic [WIDTH-1:0] d_track_q     = '0;
    logic [WIDTH-1:0] d_prior_q     = '0;
    int unsigned      jitter_lfsr_q = 32'hACE1_CAFE;

    always @(d_i) begin
        for (int b = 0; b < WIDTH; b = b + 1) begin
            if (d_i[b] !== d_track_q[b]) begin
                d_prior_q[b]  = d_track_q[b];
                d_track_q[b]  = d_i[b];
                last_chg_t[b] = $realtime;
            end
        end
    end
`endif

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            sync_meta_q <= '0;
            sync_pipe_q <= '0;
`ifdef SIM_CDC_JITTER
            jitter_lfsr_q <= 32'hACE1_CAFE;
`endif
        end else begin
`ifdef SIM_CDC_JITTER
            jitter_lfsr_q <= {jitter_lfsr_q[30:0],
                              jitter_lfsr_q[31] ^ jitter_lfsr_q[21] ^ jitter_lfsr_q[1] ^ jitter_lfsr_q[0]};
            for (int b = 0; b < WIDTH; b = b + 1) begin
                if ((($realtime - last_chg_t[b]) <= SETUP_APERTURE_NS) && jitter_lfsr_q[b % 32]) begin
                    sync_meta_q[b] <= d_prior_q[b];
                end else begin
                    sync_meta_q[b] <= d_i[b];
                end
            end
`else
            sync_meta_q <= d_i;
`endif
            sync_pipe_q[WIDTH-1:0] <= sync_meta_q;
            for (int s = 1; s < (SYNC_STAGES - 1); s = s + 1) begin
                sync_pipe_q[s*WIDTH +: WIDTH] <= sync_pipe_q[(s-1)*WIDTH +: WIDTH];
            end
        end
    end

    assign q_o = sync_pipe_q[(SYNC_STAGES-2)*WIDTH +: WIDTH];

endmodule

`default_nettype wire
