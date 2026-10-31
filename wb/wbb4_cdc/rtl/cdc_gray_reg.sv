// ==============================================================================
// Module: cdc_gray_reg
// Description:
//   Hierarchy-preserved Gray-code pointer launch register for asynchronous FIFO
//   Clock Domain Crossing (CDC) and Reset Domain Crossing (RDC).
//
//   Architectural Role:
//   - Encapsulates the source-domain Gray pointer flip-flops behind a
//     keep_hierarchy boundary so synthesis optimizers (Yosys opt_merge,
//     Synopsys DC, Cadence Genus, Vivado) never merge the Gray MSB with the
//     local binary counter MSB and never attach local combinational fanout to
//     the CDC launch net.
//   - Has no asynchronous reset (Freeze-Isolate-Then-Clear RDC discipline):
//     freezes immediately when isolate_i=1 and clears synchronously when
//     clr_i=1 after the opposite domain is isolated.
// ==============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *)
module cdc_gray_reg #(
    parameter int WIDTH = 4
) (
    input  wire              clk_i,
    input  wire              clr_i,
    input  wire              isolate_i,
    input  wire  [WIDTH-1:0] gray_d_i,
    output logic [WIDTH-1:0] gray_q_o
);

    (* keep = "true", dont_touch = "true" *)
    logic [WIDTH-1:0] gray_q;

`ifdef __ICARUS__
    initial begin
        gray_q = '0;
    end
`endif

    always_ff @(posedge clk_i) begin
        if (clr_i) begin
            gray_q <= '0;
        end else if (!isolate_i) begin
            gray_q <= gray_d_i;
        end
    end

    assign gray_q_o = gray_q;

endmodule

`default_nettype wire

