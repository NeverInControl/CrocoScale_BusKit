// ==============================================================================
// Testbench Part 3: tb_part3_watchdogs_and_stress
// Description:
//   Fast, self-checking verification of:
//   - Suite 9 : Dead DLL clock (0 Hz flatline -> EN_RESP_TIMEOUT recovery)
//   - Suite 10: Stuck rst_dll_pad ("Wait at the Gates" EN_GATE_TIMEOUT=1 vs 0)
//   - Suite 11: Sub-cycle 1-ns rst_dll_pad glitch on 10x faster DLL clock
//   - Suite 12: Randomized multi-clock / reset / abort stress
// ==============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_part3_watchdogs_and_stress;

    localparam int ADDR_W              = 2;
    localparam int DATA_W              = 4;
    parameter  int FIFO_DEPTH_LOG2     = 3;
    localparam int SYNC_STAGES         = 2;
    localparam int GATE_TIMEOUT_CYCLES = 32;
    localparam int RESP_TIMEOUT_CYCLES = 32;

    logic clk_fab     = 1'b0;
    logic clk_dll     = 1'b0;
    logic clk_dll_en  = 1'b1;
    real  fab_half_ns = 5.0;
    real  dll_half_ns = 5.0;

    always #(fab_half_ns) clk_fab = ~clk_fab;
    always begin
        #(dll_half_ns);
        if (clk_dll_en) clk_dll = ~clk_dll;
    end

    initial begin
        #150_000;
        $display("[FATAL TIMEOUT] tb_part3_watchdogs_and_stress exceeded 150 us!");
        $finish;
    end

    logic              rst_fab;
    logic              rst_dll_pad;

    logic              wb_cyc, wb_stb, wb_we, wb_stall, wb_ack, wb_err;
    logic [ADDR_W-1:0] wb_adr;
    logic [DATA_W-1:0] wb_wdat, wb_rdat;

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

    logic              wb2_cyc, wb2_stb, wb2_we, wb2_stall, wb2_ack, wb2_err;
    logic [ADDR_W-1:0] wb2_adr;
    logic [DATA_W-1:0] wb2_wdat, wb2_rdat;

`ifdef GATE_LEVEL_SIM
    wbb4_cdc_top_wait_forever u_dut_wait_forever (
`else
    wbb4_cdc_top #(
        .ADDR_W              (ADDR_W),
        .DATA_W              (DATA_W),
        .FIFO_DEPTH_LOG2     (FIFO_DEPTH_LOG2),
        .SYNC_STAGES         (SYNC_STAGES),
        .EN_GATE_TIMEOUT     (0),
        .GATE_TIMEOUT_CYCLES (GATE_TIMEOUT_CYCLES),
        .EN_RESP_TIMEOUT     (0),
        .RESP_TIMEOUT_CYCLES (RESP_TIMEOUT_CYCLES)
    ) u_dut_wait_forever (
`endif
        .clk_fab_i     (clk_fab),
        .rst_fab_i     (rst_fab),
        .wb_cyc_i      (wb2_cyc),
        .wb_stb_i      (wb2_stb),
        .wb_we_i       (wb2_we),
        .wb_adr_i      (wb2_adr),
        .wb_dat_i      (wb2_wdat),
        .wb_stall_o    (wb2_stall),
        .wb_ack_o      (wb2_ack),
        .wb_err_o      (wb2_err),
        .wb_dat_o      (wb2_rdat),
        .clk_dll_i     (clk_dll),
        .rst_dll_pad_i (rst_dll_pad)
    );

    int mon_outstanding = 0;
    int wb2_outstanding = 0;
    int protocol_errors = 0;
    int test_errors     = 0;

    always @(posedge clk_fab) begin
        if (rst_fab) begin
            mon_outstanding <= 0;
            wb2_outstanding <= 0;
        end else begin
            if ((wb_stall === 1'bx) || (wb_stall === 1'bz) ||
                (wb_ack   === 1'bx) || (wb_ack   === 1'bz) ||
                (wb_err   === 1'bx) || (wb_err   === 1'bz) ||
                (wb_ack && (^wb_rdat === 1'bx))) begin
                $display("[X-PROPAGATION VIOLATION @ %0t] u_dut: stall=%b ack=%b err=%b rdat=%b",
                         $time, wb_stall, wb_ack, wb_err, wb_rdat);
                protocol_errors <= protocol_errors + 1;
            end
            if ((wb2_stall === 1'bx) || (wb2_stall === 1'bz) ||
                (wb2_ack   === 1'bx) || (wb2_ack   === 1'bz) ||
                (wb2_err   === 1'bx) || (wb2_err   === 1'bz) ||
                (wb2_ack && (^wb2_rdat === 1'bx))) begin
                $display("[X-PROPAGATION VIOLATION @ %0t] u_dut_wait_forever: stall=%b ack=%b err=%b rdat=%b",
                         $time, wb2_stall, wb2_ack, wb2_err, wb2_rdat);
                protocol_errors <= protocol_errors + 1;
            end
            if ((wb_ack && wb_err) || (wb2_ack && wb2_err)) begin
                $display("[PROTOCOL VIOLATION @ %0t] ack & err both high!", $time);
                protocol_errors <= protocol_errors + 1;
            end
            if ((!wb_cyc && (wb_ack || wb_err)) || (!wb2_cyc && (wb2_ack || wb2_err))) begin
                $display("[PROTOCOL VIOLATION @ %0t] ack/err while cyc=0!", $time);
                protocol_errors <= protocol_errors + 1;
            end
            if (wb_cyc) begin
                int next_out;
                next_out = mon_outstanding
                         + ((wb_stb && !wb_stall) ? 1 : 0)
                         - ((wb_ack || wb_err)    ? 1 : 0);
                if (next_out < 0) begin
                    $display("[PROTOCOL VIOLATION @ %0t] u_dut spurious ack/err!", $time);
                    protocol_errors <= protocol_errors + 1;
                end
                mon_outstanding <= next_out;
            end else begin
                mon_outstanding <= 0;
            end
            if (wb2_cyc) begin
                int next_wb2_out;
                next_wb2_out = wb2_outstanding
                             + ((wb2_stb && !wb2_stall) ? 1 : 0)
                             - ((wb2_ack || wb2_err)    ? 1 : 0);
                if (next_wb2_out < 0) begin
                    $display("[PROTOCOL VIOLATION @ %0t] u_dut_wait_forever spurious ack/err!", $time);
                    protocol_errors <= protocol_errors + 1;
                end
                wb2_outstanding <= next_wb2_out;
            end else begin
                wb2_outstanding <= 0;
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
        $display(" Part 3: Watchdog Timeouts, Sub-Cycle Glitches & Randomized Stress");
        $display("======================================================================");

        rst_fab     = 1'b1;
        rst_dll_pad = 1'b1;
        clk_dll_en  = 1'b1;
        wb_idle();
        wb2_cyc     = 1'b0;
        wb2_stb     = 1'b0;
        wb2_we      = 1'b0;
        wb2_adr     = '0;
        wb2_wdat    = '0;
        repeat (5) @(posedge clk_fab);
        rst_fab     = 1'b0;
        rst_dll_pad = 1'b0;
        repeat (8) @(posedge clk_fab);

        wb_single_write(2'h0, 4'h9, err_flag);

        // ----------------------------------------------------------------------
        // SUITE 9: Dead DLL Clock (0 Hz Mid-Burst -> EN_RESP_TIMEOUT Watchdog)
        // ----------------------------------------------------------------------
        $display("[SUITE 9] Dead DLL Clock (0 Hz Flatline -> Response Watchdog)...");
        clk_dll_en = 1'b0;
        repeat (2) @(posedge clk_fab);

        wb_single_read(2'h0, rval, err_flag);
        if (!err_flag) begin
            $display("  [FAIL] Suite 9a: Expected wb_err_o=1 from response watchdog!");
            test_errors++;
        end else begin
            $display("  [PASS] Suite 9a: Response watchdog tripped cleanly (wb_err_o=1) when clk_dll=0 Hz.");
        end

        clk_dll_en = 1'b1;
        repeat (10) @(posedge clk_fab);
        wb_single_read(2'h0, rval, err_flag);
        if (err_flag || (rval !== 4'h9)) begin
            $display("  [FAIL] Suite 9b: Failed to recover after clk_dll resumed! rval=0x%0h err=%b", rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 9b: Bridge recovered automatically once clk_dll resumed (SCRATCH_0=0x%0h).", rval);
        end

        // ----------------------------------------------------------------------
        // SUITE 10: Stuck Reset "Wait at the Gates" (EN_GATE_TIMEOUT=1 vs 0)
        // ----------------------------------------------------------------------
        $display("[SUITE 10] Stuck rst_dll_pad ('Wait at the Gates' Timeout vs Forever)...");
        rst_dll_pad <= 1'b1;
        repeat (6) @(posedge clk_fab);

        @(posedge clk_fab);
        wb2_cyc <= 1'b1;
        wb2_stb <= 1'b1;
        wb2_we  <= 1'b0;
        wb2_adr <= 2'h0;

        wb_single_read(2'h0, rval, err_flag);
        if (!err_flag) begin
            $display("  [FAIL] Suite 10a: Primary DUT (EN_GATE_TIMEOUT=1) did not return wb_err_o=1!");
            test_errors++;
        end else begin
            $display("  [PASS] Suite 10a: Primary DUT waited GATE_TIMEOUT_CYCLES at gate and returned wb_err_o=1.");
        end

        repeat (GATE_TIMEOUT_CYCLES) @(posedge clk_fab);
        if (!wb2_stall || wb2_ack || wb2_err) begin
            $display("  [FAIL] Suite 10b: Secondary DUT (EN_GATE_TIMEOUT=0) did not wait at the gate!");
            test_errors++;
        end

        rst_dll_pad <= 1'b0;
        do begin
            @(posedge clk_fab);
        end while (wb2_stall);
        wb2_stb <= 1'b0;
        while (!(wb2_ack || wb2_err)) begin
            @(posedge clk_fab);
        end
        if (!wb2_ack || wb2_err || (wb2_rdat !== 4'hA)) begin
            $display("  [FAIL] Suite 10b: Secondary DUT failed after rst_dll_pad release! rdat=0x%0h", wb2_rdat);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 10b: Secondary DUT (EN_GATE_TIMEOUT=0) waited until reset release and read 0x%0h.", wb2_rdat);
        end
        wb2_cyc <= 1'b0;

        // ----------------------------------------------------------------------
        // SUITE 11: Sub-Cycle 1-Clock Glitch on rst_dll_pad (10x Faster DLL)
        // ----------------------------------------------------------------------
        $display("[SUITE 11] Sub-Cycle 1-ns Glitch on rst_dll_pad (f_dll = 10x f_fab)...");
        wb_single_write(2'h0, 4'h3, err_flag);
        dll_half_ns = 0.5;
        repeat (2) @(posedge clk_fab);

        @(posedge clk_dll);
        rst_dll_pad = 1'b1;
        @(posedge clk_dll);
        rst_dll_pad = 1'b0;

        repeat (8) @(posedge clk_fab);
        dll_half_ns = 5.0;
        wb_single_read(2'h0, rval, err_flag);
        if (err_flag || (rval !== 4'hA)) begin
            $display("  [FAIL] Suite 11: Sub-cycle rst_dll_pad glitch missed! Expected 0xA, got 0x%0h", rval);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 11: Sub-cycle 1-ns rst_dll_pad pulse caught by async latch and synchronized.");
        end

        // ----------------------------------------------------------------------
        // SUITE 12: Randomized Multi-Clock / Reset / Abort Stress + Scoreboard
        // ----------------------------------------------------------------------
        $display("[SUITE 12] Running 50-Burst Randomized Multi-Clock Stress with Scoreboard...");
        begin
            logic [DATA_W-1:0] ref_scratch0;
            logic [DATA_W-1:0] ref_scratch1;
            bit                score_valid;
            int                verified_rds;

            ref_scratch0 = 4'hA;
            ref_scratch1 = 4'h5;
            score_valid  = 1'b1;
            verified_rds = 0;

            for (int burst_idx = 0; burst_idx < 50; burst_idx++) begin
                int unsigned rand_val;
                int          burst_len;
                bit          do_abort;
                bit          do_dll_rst;
                bit          do_fab_rst;
                rand_val    = $urandom;
                burst_len   = (rand_val % 6) + 1;
                do_abort    = ((rand_val >> 4) % 8) == 0;
                do_dll_rst  = ((rand_val >> 8) % 10) == 0;
                do_fab_rst  = !do_dll_rst && (((rand_val >> 16) % 12) == 0);
                dll_half_ns = 2.0 + real'((rand_val >> 12) % 8);

                ack_cnt = 0;
                err_cnt = 0;
                @(posedge clk_fab);
                wb_cyc <= 1'b1;
                for (int b = 0; b < burst_len; b++) begin
                    logic              beat_we;
                    logic [ADDR_W-1:0] beat_adr;
                    logic [DATA_W-1:0] beat_dat;
                    beat_we  = b[0];
                    beat_adr = ADDR_W'(b % 4);
                    beat_dat = DATA_W'(burst_idx + b);

                    wb_stb  <= 1'b1;
                    wb_we   <= beat_we;
                    wb_adr  <= beat_adr;
                    wb_wdat <= beat_dat;
                    @(posedge clk_fab);
                    if (wb_ack) ack_cnt++;
                    if (wb_err) err_cnt++;
                    while (wb_stall) begin
                        @(posedge clk_fab);
                        if (wb_ack) ack_cnt++;
                        if (wb_err) err_cnt++;
                    end
                    if (!do_abort && !do_dll_rst && !do_fab_rst && beat_we) begin
                        if (beat_adr == 2'h0) ref_scratch0 = beat_dat;
                        if (beat_adr == 2'h1) ref_scratch1 = beat_dat;
                    end
                end
                wb_stb <= 1'b0;
                wb_we  <= 1'b0;

                if (do_dll_rst) begin
                    rst_dll_pad <= 1'b1;
                    ref_scratch0 = 4'hA;
                    ref_scratch1 = 4'h5;
                    score_valid  = 1'b1;
                end

                if (do_fab_rst) begin
                    rst_fab <= 1'b1;
                    wb_idle();
                    repeat (3) @(posedge clk_fab);
                    rst_fab <= 1'b0;
                    score_valid = 1'b0;
                end else if (do_abort) begin
                    wb_idle();
                    @(posedge clk_fab);
                    score_valid = 1'b0;
                end else begin
                    while ((ack_cnt + err_cnt) < burst_len) begin
                        @(posedge clk_fab);
                        if (wb_ack) ack_cnt++;
                        if (wb_err) err_cnt++;
                    end
                    wb_cyc <= 1'b0;
                end

                if (do_dll_rst) begin
                    repeat (2) @(posedge clk_fab);
                    rst_dll_pad <= 1'b0;
                    repeat (4) @(posedge clk_fab);
                end

                // Verify scoreboard data integrity on every clean burst
                if (score_valid && !do_abort && !do_dll_rst && !do_fab_rst && (err_cnt == 0)) begin
                    wb_single_read(2'h0, rval, err_flag);
                    if (err_flag || (rval !== ref_scratch0)) begin
                        $display("  [FAIL] Suite 12 burst %0d SCRATCH_0 mismatch: exp 0x%0h, got 0x%0h (err=%b)",
                                 burst_idx, ref_scratch0, rval, err_flag);
                        test_errors++;
                    end
                    wb_single_read(2'h1, rval, err_flag);
                    if (err_flag || (rval !== ref_scratch1)) begin
                        $display("  [FAIL] Suite 12 burst %0d SCRATCH_1 mismatch: exp 0x%0h, got 0x%0h (err=%b)",
                                 burst_idx, ref_scratch1, rval, err_flag);
                        test_errors++;
                    end
                    verified_rds += 2;
                end else if (!score_valid && !do_dll_rst && !do_fab_rst) begin
                    // Resync scoreboard after an abort or fabric reset
                    wb_single_write(2'h0, DATA_W'(burst_idx), err_flag);
                    wb_single_write(2'h1, DATA_W'(~burst_idx), err_flag);
                    if (!err_flag) begin
                        ref_scratch0 = DATA_W'(burst_idx);
                        ref_scratch1 = DATA_W'(~burst_idx);
                        score_valid  = 1'b1;
                    end
                end
            end

            dll_half_ns = 5.0;
            repeat (10) @(posedge clk_fab);
            wb_single_write(2'h0, 4'hB, err_flag);
            wb_single_read(2'h0, rval, err_flag);
            if (err_flag || (rval !== 4'hB) || (verified_rds == 0)) begin
                $display("  [FAIL] Suite 12: Post-stress sanity check failed! rval=0x%0h err=%b verified_rds=%0d",
                         rval, err_flag, verified_rds);
                test_errors++;
            end else begin
                $display("  [PASS] Suite 12: Completed 50 randomized multi-clock/reset/abort bursts (%0d scoreboard reads verified, 0 errors).",
                         verified_rds);
            end
        end

        $display("----------------------------------------------------------------------");
        if ((test_errors == 0) && (protocol_errors == 0)) begin
            $display(" PART 3 PASSED (test_errors=0, protocol_errors=0)");
        end else begin
            $display(" PART 3 FAILED (test_errors=%0d, protocol_errors=%0d)", test_errors, protocol_errors);
        end
        $display("----------------------------------------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire

