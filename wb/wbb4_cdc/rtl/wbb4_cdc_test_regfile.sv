// ==============================================================================
// Module: wbb4_cdc_test_regfile
// Description:
//   Single-cycle, zero-stall Wishbone B4 Pipelined Slave Register File in the
//   DLL clock domain for CDC and burst throughput verification.
//   Uses zero-initialized flip-flops (XORed with reset seed constants 0xA / 0x5)
//   so every register maps directly to sg13cmos5l_dfrbp_1 in IHP 130nm.
// ==============================================================================

`default_nettype none

module wbb4_cdc_test_regfile #(
    parameter int ADDR_W = 2,
    parameter int DATA_W = 4
) (
    input  wire               clk_dll_i,
    input  wire               rst_dll_i,   // AASD reset in clk_dll_i
    input  wire               wb_cyc_i,
    input  wire               wb_stb_i,
    input  wire               wb_we_i,
    input  wire  [ADDR_W-1:0] wb_adr_i,
    input  wire  [DATA_W-1:0] wb_dat_i,
    output logic              wb_stall_o,
    output logic              wb_ack_o,
    output logic              wb_err_o,
    output logic [DATA_W-1:0] wb_dat_o
);

    logic [DATA_W-1:0] scratch0_raw_q;
    logic [DATA_W-1:0] scratch1_raw_q;
    logic [DATA_W-1:0] chg_cnt_q;
    logic [DATA_W-1:0] prev_wdat_q;
    logic [DATA_W-1:0] osc_cnt_q;

    logic              ack_q;
    logic [DATA_W-1:0] rdat_q;

    wire  [DATA_W-1:0] scratch0_val = scratch0_raw_q ^ DATA_W'(4'hA);
    wire  [DATA_W-1:0] scratch1_val = scratch1_raw_q ^ DATA_W'(4'h5);

    assign wb_stall_o = 1'b0;
    assign wb_err_o   = 1'b0;
    assign wb_ack_o   = wb_cyc_i && ack_q;
    assign wb_dat_o   = wb_ack_o ? rdat_q : '0;

    wire req_valid = wb_cyc_i && wb_stb_i;

    always_ff @(posedge clk_dll_i or posedge rst_dll_i) begin
        if (rst_dll_i) begin
            scratch0_raw_q <= '0;
            scratch1_raw_q <= '0;
            chg_cnt_q      <= '0;
            prev_wdat_q    <= '0;
            osc_cnt_q      <= '0;
            ack_q          <= 1'b0;
            rdat_q         <= '0;
        end else begin
            osc_cnt_q <= osc_cnt_q + 1'b1;
            ack_q     <= req_valid;

            if (req_valid) begin
                if (wb_we_i) begin
                    case (wb_adr_i)
                        ADDR_W'(0): scratch0_raw_q <= wb_dat_i ^ DATA_W'(4'hA);
                        ADDR_W'(1): scratch1_raw_q <= wb_dat_i ^ DATA_W'(4'h5);
                        ADDR_W'(2): begin
                            if (wb_dat_i != prev_wdat_q) begin
                                chg_cnt_q   <= chg_cnt_q + 1'b1;
                                prev_wdat_q <= wb_dat_i;
                            end
                        end
                        ADDR_W'(3): begin
                            chg_cnt_q   <= '0;
                            prev_wdat_q <= wb_dat_i;
                        end
                        default: ;
                    endcase
                end

                case (wb_adr_i)
                    ADDR_W'(0): rdat_q <= scratch0_val;
                    ADDR_W'(1): rdat_q <= scratch1_val;
                    ADDR_W'(2): rdat_q <= chg_cnt_q;
                    ADDR_W'(3): rdat_q <= osc_cnt_q;
                    default:    rdat_q <= '0;
                endcase
            end
        end
    end

endmodule

`default_nettype wire

