// ==============================================================================
// Module: rst_sync_aasd
// Description:
//   Asynchronous-Assert, Synchronous-Deassert (AASD) Reset Synchronizer Bridge.
//   Uses active-low internal clear registers (rst_n_pipe_q <= '0 on async reset)
//   so every stage maps directly to native sg13cmos5l_dfrbp_1 clear flip-flops
//   in IHP 130nm (which lacks async-preset cells).
// ==============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *)
module rst_sync_aasd #(
    parameter int SYNC_STAGES = 2
) (
    input  wire  clk_i,
    input  wire  rst_async_i,
    output logic rst_sync_o
);

    // Stage 0 (rst_meta_n_q) and Stage 1..N (rst_sync_n_q) are named distinctly
    // so SDC constraints can false-path only the asynchronous RESET_B pins while
    // keeping the internal synchronous shift path (rst_meta_n_q -> rst_sync_n_q)
    // and downstream reset recovery/removal paths strictly timed.
    (* keep = "true", async_reg = "true", dont_touch = "true" *)
    logic                   rst_meta_n_q;

    (* keep = "true", async_reg = "true", dont_touch = "true" *)
    logic [SYNC_STAGES-2:0] rst_sync_n_q;

    always_ff @(posedge clk_i or posedge rst_async_i) begin
        if (rst_async_i) begin
            rst_meta_n_q <= 1'b0;
            rst_sync_n_q <= '0;
        end else begin
            rst_meta_n_q    <= 1'b1;
            rst_sync_n_q[0] <= rst_meta_n_q;
            for (int s = 1; s < (SYNC_STAGES - 1); s = s + 1) begin
                rst_sync_n_q[s] <= rst_sync_n_q[s - 1];
            end
        end
    end

    assign rst_sync_o = ~rst_sync_n_q[SYNC_STAGES - 2];

endmodule

`default_nettype wire
