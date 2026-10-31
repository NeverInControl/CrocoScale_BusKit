// ==============================================================================
// Testbench Part 2: tb_part2_resets_and_aborts
// Description:
//   Fast, self-checking verification of:
//   - Suite 5: External rst_dll_pad pulled mid-burst (in-flight wb_err_o drain)
//   - Suite 6: Fabric rst_fab pulled mid-burst (4-phase FIFO recovery)
//   - Suite 7: Wishbone Master Abort mid-burst (wb_cyc_i drop + discard_cnt)
//   - Suite 8: Rapid back-to-back burst-and-abort overflow guard
// ==============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_part2_resets_and_aborts;

    localparam int ADDR_W              = 2;
    localparam int DATA_W              = 4;
    parameter  int FIFO_DEPTH_LOG2     = 3;
    localparam int SYNC_STAGES         = 2;
    localparam int GATE_TIMEOUT_CYCLES = 32;
    localparam int RESP_TIMEOUT_CYCLES = 32;

    logic clk_fab     = 1'b0;
    logic clk_dll     = 1'b0;
    real  fab_half_ns = 5.0;
    real  dll_half_ns = 5.0;

    always #(fab_half_ns) clk_fab = ~clk_fab;
    always #(dll_half_ns) clk_dll = ~clk_dll;

    initial begin
        #100_000;
        $display("[FATAL TIMEOUT] tb_part2_resets_and_aborts exceeded 100 us!");
        $finish;
    end

    logic              rst_fab;
    logic              rst_dll_pad;
    logic              wb_cyc;
    logic              wb_stb;
    logic              wb_we;
    logic [ADDR_W-1:0] wb_adr;
    logic [DATA_W-1:0] wb_wdat;
    logic              wb_stall;
    logic              wb_ack;
    logic              wb_err;
    logic [DATA_W-1:0] wb_rdat;

`ifdef GATE_LEVEL_SIM
    `ifndef GLS_DUT_NAME
        `define GLS_DUT_NAME wbb4_cdc_top
    `endif
    `GLS_DUT_NAME u_dut (
`else
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
`endif
        .clk_fab_i     (clk_fab),
        .rst_fab_i     (rst_fab),
        .wb_cyc_i      (wb_cyc),
        .wb_stb_i      (wb_stb),
        .wb_we_i       (wb_we),
        .wb_adr_i      (wb_adr),
        .wb_dat_i      (wb_wdat),
        .wb_stall_o    (wb_stall),
        .wb_ack_o      (wb_ack),
        .wb_err_o      (wb_err),
        .wb_dat_o      (wb_rdat),
        .clk_dll_i     (clk_dll),
        .rst_dll_pad_i (rst_dll_pad)
    );

    int mon_outstanding = 0;
    int protocol_errors = 0;
    int test_errors     = 0;

    always @(posedge clk_fab) begin
        if (rst_fab) begin
            mon_outstanding <= 0;
        end else begin
            if ((wb_stall === 1'bx) || (wb_stall === 1'bz) ||
                (wb_ack   === 1'bx) || (wb_ack   === 1'bz) ||
                (wb_err   === 1'bx) || (wb_err   === 1'bz) ||
                (wb_ack && (^wb_rdat === 1'bx))) begin
                $display("[X-PROPAGATION VIOLATION @ %0t] stall=%b ack=%b err=%b rdat=%b",
                         $time, wb_stall, wb_ack, wb_err, wb_rdat);
                protocol_errors <= protocol_errors + 1;
            end
            if (wb_ack && wb_err) begin
                $display("[PROTOCOL VIOLATION @ %0t] ack & err both high!", $time);
                protocol_errors <= protocol_errors + 1;
            end
            if (!wb_cyc && (wb_ack || wb_err)) begin
                $display("[PROTOCOL VIOLATION @ %0t] ack/err while cyc=0!", $time);
                protocol_errors <= protocol_errors + 1;
            end
            if (wb_cyc) begin
                int next_out;
                next_out = mon_outstanding
                         + ((wb_stb && !wb_stall) ? 1 : 0)
                         - ((wb_ack || wb_err)    ? 1 : 0);
                if (next_out < 0) begin
                    $display("[PROTOCOL VIOLATION @ %0t] Spurious ack/err!", $time);
                    protocol_errors <= protocol_errors + 1;
                end
                mon_outstanding <= next_out;
            end else begin
                mon_outstanding <= 0;
            end
        end
    end

    task automatic wb_idle();
        wb_cyc  <= 1'b0;
        wb_stb  <= 1'b0;
        wb_we   <= 1'b0;
        wb_adr  <= '0;
        wb_wdat <= '0;
    endtask

    task automatic wb_single_write(
        input  logic [ADDR_W-1:0] adr,
        input  logic [DATA_W-1:0] dat,
        output logic              got_err
    );
        @(posedge clk_fab);
        wb_cyc  <= 1'b1;
        wb_stb  <= 1'b1;
        wb_we   <= 1'b1;
        wb_adr  <= adr;
        wb_wdat <= dat;
        do begin
            @(posedge clk_fab);
        end while (wb_stall);
        wb_stb <= 1'b0;
        while (!(wb_ack || wb_err)) begin
            @(posedge clk_fab);
        end
        got_err = wb_err;
        wb_cyc  <= 1'b0;
        wb_we   <= 1'b0;
    endtask

    task automatic wb_single_read(
        input  logic [ADDR_W-1:0] adr,
        output logic [DATA_W-1:0] rdat,
        output logic              got_err
    );
        @(posedge clk_fab);
        wb_cyc  <= 1'b1;
        wb_stb  <= 1'b1;
        wb_we   <= 1'b0;
        wb_adr  <= adr;
        wb_wdat <= '0;
        do begin
            @(posedge clk_fab);
        end while (wb_stall);
        wb_stb <= 1'b0;
        while (!(wb_ack || wb_err)) begin
            @(posedge clk_fab);
        end
        rdat    = wb_rdat;
        got_err = wb_err;
        wb_cyc  <= 1'b0;
    endtask

    initial begin
        logic [DATA_W-1:0] rval;
        logic              err_flag;
        int                ack_cnt, err_cnt;

        $display("======================================================================");
        $display(" Part 2: Mid-Burst Independent Resets & Wishbone Master Aborts");
        $display("======================================================================");

        rst_fab     = 1'b1;
        rst_dll_pad = 1'b1;
        wb_idle();
        repeat (5) @(posedge clk_fab);
        rst_fab     = 1'b0;
        rst_dll_pad = 1'b0;
        repeat (8) @(posedge clk_fab);

        // ----------------------------------------------------------------------
        // SUITE 5: External rst_dll_pad Pulled Mid-Burst (Asymmetric Slave Reset)
        // ----------------------------------------------------------------------
        $display("[SUITE 5] External rst_dll_pad Pulled Mid-Burst...");
        wb_single_write(2'h0, 4'hD, err_flag);
        dll_half_ns = 15.0;
        repeat (4) @(posedge clk_fab);

        ack_cnt = 0;
        err_cnt = 0;
        @(posedge clk_fab);
        wb_cyc <= 1'b1;
        wb_we  <= 1'b0;
        wb_adr <= 2'h0;
        for (int beat = 0; beat < 8; beat++) begin
            wb_stb <= 1'b1;
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
            if (wb_err) err_cnt++;
            while (wb_stall) begin
                @(posedge clk_fab);
                if (wb_ack) ack_cnt++;
                if (wb_err) err_cnt++;
            end
        end
        wb_stb <= 1'b0;

        while ((ack_cnt + err_cnt) < 1) begin
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
            if (wb_err) err_cnt++;
        end

        rst_dll_pad <= 1'b1;
        while ((ack_cnt + err_cnt) < 8) begin
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
            if (wb_err) err_cnt++;
        end
        wb_cyc <= 1'b0;

        repeat (4) @(posedge clk_fab);
        rst_dll_pad <= 1'b0;
        dll_half_ns = 5.0;

        wb_single_read(2'h0, rval, err_flag);
        if ((err_cnt == 0) || ((ack_cnt + err_cnt) != 8) || err_flag || (rval !== 4'hA)) begin
            $display("  [FAIL] Suite 5: ack_cnt=%0d, err_cnt=%0d, rval=0x%0h (err=%b)",
                     ack_cnt, err_cnt, rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 5: Mid-burst rst_dll_pad drained (%0d acks, %0d errs) & recovered (SCRATCH_0=0x%0h).",
                     ack_cnt, err_cnt, rval);
        end

        // ----------------------------------------------------------------------
        // SUITE 6: Fabric rst_fab Pulled Mid-Burst (Asymmetric Master Reset)
        // ----------------------------------------------------------------------
        $display("[SUITE 6] Fabric rst_fab Pulled Mid-Burst...");
        wb_single_write(2'h0, 4'h7, err_flag);
        dll_half_ns = 12.0;

        @(posedge clk_fab);
        wb_cyc  <= 1'b1;
        wb_stb  <= 1'b1;
        wb_we   <= 1'b1;
        wb_adr  <= 2'h1;
        wb_wdat <= 4'hE;
        repeat (5) @(posedge clk_fab);

        rst_fab <= 1'b1;
        wb_idle();
        repeat (4) @(posedge clk_fab);
        rst_fab <= 1'b0;
        dll_half_ns = 5.0;

        wb_single_read(2'h0, rval, err_flag);
        if (err_flag || (rval !== 4'h7)) begin
            $display("  [FAIL] Suite 6: Expected 0x7, got 0x%0h (err=%b)", rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 6: Mid-burst rst_fab recovered via 4-phase FIFO clear (SCRATCH_0=0x%0h).", rval);
        end

        // ----------------------------------------------------------------------
        // SUITE 7: Wishbone Master Abort Mid-Burst (wb_cyc_i Dropped Early)
        // ----------------------------------------------------------------------
        $display("[SUITE 7] Wishbone Master Abort Mid-Burst (wb_cyc_i drop + discard_cnt)...");
        wb_single_write(2'h0, 4'h9, err_flag);
        wb_single_write(2'h1, 4'h6, err_flag);

        dll_half_ns = 15.0;
        repeat (3) @(posedge clk_fab);

        @(posedge clk_fab);
        wb_cyc <= 1'b1;
        wb_we  <= 1'b0;
        wb_adr <= 2'h0;
        for (int beat = 0; beat < 6; beat++) begin
            wb_stb <= 1'b1;
            @(posedge clk_fab);
            while (wb_stall) @(posedge clk_fab);
        end
        wb_idle();
        @(posedge clk_fab);

        wb_single_read(2'h1, rval, err_flag);
        dll_half_ns = 5.0;

        if (err_flag || (rval !== 4'h6)) begin
            $display("  [FAIL] Suite 7: Aliasing after abort! Expected 0x6, got 0x%0h (err=%b)", rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 7: All 6 aborted beats swallowed by discard_cnt; new read returned 0x%0h.", rval);
        end

        // ----------------------------------------------------------------------
        // SUITE 8: Pathological Rapid Burst-and-Abort Stress (Overflow Guard)
        // ----------------------------------------------------------------------
        $display("[SUITE 8] Rapid Back-to-Back Burst-and-Abort Stress...");
        dll_half_ns = 20.0;
        for (int iter = 0; iter < 10; iter++) begin
            @(posedge clk_fab);
            wb_cyc <= 1'b1;
            wb_stb <= 1'b1;
            wb_we  <= 1'b0;
            wb_adr <= 2'h0;
            repeat (4) @(posedge clk_fab);
            wb_idle();
            @(posedge clk_fab);
        end
        dll_half_ns = 5.0;
        wb_single_read(2'h1, rval, err_flag);
        if (err_flag || (rval !== 4'h6)) begin
            $display("  [FAIL] Suite 8: Post-abort-stress read failed: got 0x%0h (err=%b)", rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 8: Survived 10 rapid burst-abort loops without counter overflow.");
        end

        $display("----------------------------------------------------------------------");
        if ((test_errors == 0) && (protocol_errors == 0)) begin
            $display(" PART 2 PASSED (test_errors=0, protocol_errors=0)");
        end else begin
            $display(" PART 2 FAILED (test_errors=%0d, protocol_errors=%0d)", test_errors, protocol_errors);
        end
        $display("----------------------------------------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire

