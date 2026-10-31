// ==============================================================================
// Testbench Part 1: tb_part1_bursts_and_skew
// Description:
//   Fast, self-checking verification of:
//   - Suite 1: Startup & reset release skew ("Wait at the Gates")
//   - Suite 2: Reset defaults & scratchpad R/W integrity (0x0, 0x1)
//   - Suite 3: Full-bandwidth 8-beat write burst to BURST_CHG_CNT (0x2) &
//              duplicate-value transition filter
//   - Suite 4: Full-bandwidth 8-beat read burst of CLK_OSC_CNT (0x3) verifying
//              zero stalls and consecutive +1 cycle increments
// ==============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_part1_bursts_and_skew;

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
        $display("[FATAL TIMEOUT] tb_part1_bursts_and_skew exceeded 100 us!");
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

    // Secondary DUT verifying non-default FIFO_DEPTH_LOG2=4 (16 entries) & SYNC_STAGES=3
    logic              deep_cyc   = 1'b0;
    logic              deep_stb   = 1'b0;
    logic              deep_we    = 1'b0;
    logic [ADDR_W-1:0] deep_adr   = '0;
    logic [DATA_W-1:0] deep_wdat  = '0;
    logic              deep_stall;
    logic              deep_ack;
    logic              deep_err;
    logic [DATA_W-1:0] deep_rdat;

`ifdef GATE_LEVEL_SIM
    wbb4_cdc_top_deep u_dut_deep (
`else
    wbb4_cdc_top #(
        .ADDR_W              (ADDR_W),
        .DATA_W              (DATA_W),
        .FIFO_DEPTH_LOG2     (4),
        .SYNC_STAGES         (3),
        .EN_GATE_TIMEOUT     (1),
        .GATE_TIMEOUT_CYCLES (GATE_TIMEOUT_CYCLES),
        .EN_RESP_TIMEOUT     (1),
        .RESP_TIMEOUT_CYCLES (RESP_TIMEOUT_CYCLES)
    ) u_dut_deep (
`endif
        .clk_fab_i     (clk_fab),
        .rst_fab_i     (rst_fab),
        .wb_cyc_i      (deep_cyc),
        .wb_stb_i      (deep_stb),
        .wb_we_i       (deep_we),
        .wb_adr_i      (deep_adr),
        .wb_dat_i      (deep_wdat),
        .wb_stall_o    (deep_stall),
        .wb_ack_o      (deep_ack),
        .wb_err_o      (deep_err),
        .wb_dat_o      (deep_rdat),
        .clk_dll_i     (clk_dll),
        .rst_dll_pad_i (rst_dll_pad)
    );

    int mon_outstanding  = 0;
    int deep_outstanding = 0;
    int protocol_errors  = 0;
    int test_errors      = 0;

    always @(posedge clk_fab) begin
        if (rst_fab) begin
            mon_outstanding  <= 0;
            deep_outstanding <= 0;
        end else begin
            if ((wb_stall === 1'bx) || (wb_stall === 1'bz) ||
                (wb_ack   === 1'bx) || (wb_ack   === 1'bz) ||
                (wb_err   === 1'bx) || (wb_err   === 1'bz) ||
                (wb_ack && (^wb_rdat === 1'bx))) begin
                $display("[X-PROPAGATION VIOLATION @ %0t] u_dut: stall=%b ack=%b err=%b rdat=%b",
                         $time, wb_stall, wb_ack, wb_err, wb_rdat);
                protocol_errors <= protocol_errors + 1;
            end
            if ((deep_stall === 1'bx) || (deep_stall === 1'bz) ||
                (deep_ack   === 1'bx) || (deep_ack   === 1'bz) ||
                (deep_err   === 1'bx) || (deep_err   === 1'bz) ||
                (deep_ack && (^deep_rdat === 1'bx))) begin
                $display("[X-PROPAGATION VIOLATION @ %0t] u_dut_deep: stall=%b ack=%b err=%b rdat=%b",
                         $time, deep_stall, deep_ack, deep_err, deep_rdat);
                protocol_errors <= protocol_errors + 1;
            end
            if ((wb_ack && wb_err) || (deep_ack && deep_err)) begin
                $display("[PROTOCOL VIOLATION @ %0t] ack & err both high!", $time);
                protocol_errors <= protocol_errors + 1;
            end
            if ((!wb_cyc && (wb_ack || wb_err)) || (!deep_cyc && (deep_ack || deep_err))) begin
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
            if (deep_cyc) begin
                int next_deep_out;
                next_deep_out = deep_outstanding
                              + ((deep_stb && !deep_stall) ? 1 : 0)
                              - ((deep_ack || deep_err)    ? 1 : 0);
                if (next_deep_out < 0) begin
                    $display("[PROTOCOL VIOLATION @ %0t] u_dut_deep spurious ack/err!", $time);
                    protocol_errors <= protocol_errors + 1;
                end
                deep_outstanding <= next_deep_out;
            end else begin
                deep_outstanding <= 0;
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
        logic [DATA_W-1:0] burst_rdata [0:7];
        int                stall_cycles_seen;
        int                ack_cnt;
        bit                osc_ok;

        $display("======================================================================");
        $display(" Part 1: Startup Skew, Scratchpad & Full-Bandwidth Burst Verification");
        $display("======================================================================");

        rst_fab     = 1'b1;
        rst_dll_pad = 1'b1;
        wb_idle();
        repeat (5) @(posedge clk_fab);

        // ----------------------------------------------------------------------
        // SUITE 1: Startup & Reset Release Skew ("Wait at the Gates")
        // ----------------------------------------------------------------------
        $display("[SUITE 1] Startup & Reset Release Skew (Wait at the Gates)...");
        @(posedge clk_fab);
        rst_fab <= 1'b0;
        fork
            begin
                repeat (10) @(posedge clk_fab);
                rst_dll_pad <= 1'b0;
            end
        join_none

        wb_single_read(2'h0, rval, err_flag);
        if (err_flag || (rval !== 4'hA)) begin
            $display("  [FAIL] Suite 1: Expected 0xA, got 0x%0h (err=%b)", rval, err_flag);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 1: Master waited at gate during reset skew and read SCRATCH_0=0x%0h.", rval);
        end

        // ----------------------------------------------------------------------
        // SUITE 2: Reset Defaults & Scratchpad R/W
        // ----------------------------------------------------------------------
        $display("[SUITE 2] Reset Defaults & Scratchpad R/W...");
        wb_single_read(2'h1, rval, err_flag);
        if (err_flag || (rval !== 4'h5)) begin
            $display("  [FAIL] Suite 2: Expected SCRATCH_1=0x5, got 0x%0h", rval);
            test_errors++;
        end
        wb_single_write(2'h0, 4'hC, err_flag);
        wb_single_write(2'h1, 4'h3, err_flag);
        wb_single_read(2'h0, rval, err_flag);
        if (rval !== 4'hC) test_errors++;
        wb_single_read(2'h1, rval, err_flag);
        if (rval !== 4'h3) begin
            $display("  [FAIL] Suite 2: R/W mismatch got 0x%0h", rval);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 2: Scratchpad R/W verified (0x0=0xC, 0x1=0x3).");
        end

        // ----------------------------------------------------------------------
        // SUITE 3: Full-Bandwidth 8-Beat Write Burst to BURST_CHG_CNT (2'h2)
        // ----------------------------------------------------------------------
        $display("[SUITE 3] Full-Bandwidth 8-Beat Write Burst to BURST_CHG_CNT (2'h2)...");
        wb_single_write(2'h3, 4'h0, err_flag);

        stall_cycles_seen = 0;
        ack_cnt           = 0;
        @(posedge clk_fab);
        wb_cyc <= 1'b1;
        wb_we  <= 1'b1;
        wb_adr <= 2'h2;
        for (int beat = 1; beat <= 8; beat++) begin
            wb_stb  <= 1'b1;
            wb_wdat <= DATA_W'(beat);
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
            while (wb_stall) begin
                stall_cycles_seen++;
                @(posedge clk_fab);
                if (wb_ack) ack_cnt++;
            end
        end
        wb_stb <= 1'b0;
        wb_we  <= 1'b0;
        while (ack_cnt < 8) begin
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
        end
        wb_cyc <= 1'b0;

        wb_single_read(2'h2, rval, err_flag);
        if (FIFO_DEPTH_LOG2 >= 3) begin
            if ((stall_cycles_seen != 0) || (rval !== 4'd8)) begin
                $display("  [FAIL] Suite 3a: stalls=%0d, chg_cnt=%0d (exp 0, 8)", stall_cycles_seen, rval);
                test_errors++;
            end else begin
                $display("  [PASS] Suite 3a: 8-beat write burst had 0 stalls and chg_cnt=8.");
            end
        end else begin
            if ((stall_cycles_seen == 0) || (rval !== 4'd8)) begin
                $display("  [FAIL] Suite 3a (DEPTH=%0d): stalls=%0d (exp >0), chg_cnt=%0d (exp 8)",
                         (1 << FIFO_DEPTH_LOG2), stall_cycles_seen, rval);
                test_errors++;
            end else begin
                $display("  [PASS] Suite 3a (DEPTH=%0d): 8-beat write burst throttled cleanly (stalls=%0d) and chg_cnt=8.",
                         (1 << FIFO_DEPTH_LOG2), stall_cycles_seen);
            end
        end

        wb_single_write(2'h3, 4'h0, err_flag);
        ack_cnt = 0;
        @(posedge clk_fab);
        wb_cyc <= 1'b1;
        wb_we  <= 1'b1;
        wb_adr <= 2'h2;
        for (int beat = 0; beat < 8; beat++) begin
            wb_stb  <= 1'b1;
            wb_wdat <= DATA_W'((beat / 2) + 1);
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
            while (wb_stall) begin
                @(posedge clk_fab);
                if (wb_ack) ack_cnt++;
            end
        end
        wb_stb <= 1'b0;
        wb_we  <= 1'b0;
        while (ack_cnt < 8) begin
            @(posedge clk_fab);
            if (wb_ack) ack_cnt++;
        end
        wb_cyc <= 1'b0;

        wb_single_read(2'h2, rval, err_flag);
        if (rval !== 4'd4) begin
            $display("  [FAIL] Suite 3b: Expected chg_cnt=4, got %0d", rval);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 3b: Duplicate-value write filter verified (chg_cnt=4).");
        end

        // ----------------------------------------------------------------------
        // SUITE 4: Full-Bandwidth 8-Beat Read Burst of CLK_OSC_CNT (2'h3)
        // ----------------------------------------------------------------------
        $display("[SUITE 4] Full-Bandwidth 8-Beat Read Burst of CLK_OSC_CNT (2'h3)...");
        dll_half_ns = 12.5;
        repeat (6) @(posedge clk_fab);

        stall_cycles_seen = 0;
        ack_cnt           = 0;
        @(posedge clk_fab);
        wb_cyc <= 1'b1;
        wb_we  <= 1'b0;
        wb_adr <= 2'h3;
        for (int beat = 0; beat < 8; beat++) begin
            wb_stb <= 1'b1;
            @(posedge clk_fab);
            if (wb_ack) begin
                burst_rdata[ack_cnt] = wb_rdat;
                ack_cnt++;
            end
            while (wb_stall) begin
                stall_cycles_seen++;
                @(posedge clk_fab);
                if (wb_ack) begin
                    burst_rdata[ack_cnt] = wb_rdat;
                    ack_cnt++;
                end
            end
        end
        wb_stb <= 1'b0;
        while (ack_cnt < 8) begin
            @(posedge clk_fab);
            if (wb_ack) begin
                burst_rdata[ack_cnt] = wb_rdat;
                ack_cnt++;
            end
        end
        wb_cyc <= 1'b0;

        if (FIFO_DEPTH_LOG2 >= 3) begin
            osc_ok = (stall_cycles_seen == 0);
            for (int i = 1; i < 8; i++) begin
                if (burst_rdata[i] !== DATA_W'(burst_rdata[i-1] + 4'd1)) begin
                    osc_ok = 1'b0;
                end
            end
            if (!osc_ok) begin
                $display("  [FAIL] Suite 4: stalls=%0d, seq=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                         stall_cycles_seen,
                         burst_rdata[0], burst_rdata[1], burst_rdata[2], burst_rdata[3],
                         burst_rdata[4], burst_rdata[5], burst_rdata[6], burst_rdata[7]);
                test_errors++;
            end else begin
                $display("  [PASS] Suite 4: 8-beat CLK_OSC_CNT read burst had 0 stalls and consecutive +1 steps: [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d].",
                         burst_rdata[0], burst_rdata[1], burst_rdata[2], burst_rdata[3],
                         burst_rdata[4], burst_rdata[5], burst_rdata[6], burst_rdata[7]);
            end
        end else begin
            osc_ok = (stall_cycles_seen > 0);
            for (int i = 1; i < 8; i++) begin
                if (burst_rdata[i] === burst_rdata[i-1]) begin
                    osc_ok = 1'b0;
                end
            end
            if (!osc_ok) begin
                $display("  [FAIL] Suite 4 (DEPTH=%0d): stalls=%0d, seq=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                         (1 << FIFO_DEPTH_LOG2), stall_cycles_seen,
                         burst_rdata[0], burst_rdata[1], burst_rdata[2], burst_rdata[3],
                         burst_rdata[4], burst_rdata[5], burst_rdata[6], burst_rdata[7]);
                test_errors++;
            end else begin
                $display("  [PASS] Suite 4 (DEPTH=%0d): 8-beat CLK_OSC_CNT read burst throttled cleanly (stalls=%0d) with advancing steps: [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d].",
                         (1 << FIFO_DEPTH_LOG2), stall_cycles_seen,
                         burst_rdata[0], burst_rdata[1], burst_rdata[2], burst_rdata[3],
                         burst_rdata[4], burst_rdata[5], burst_rdata[6], burst_rdata[7]);
            end
        end

        // ----------------------------------------------------------------------
        // SUITE 4b: Parameterized FIFO_DEPTH_LOG2=4 (16 entries), SYNC_STAGES=3
        // ----------------------------------------------------------------------
        $display("[SUITE 4b] Parameterized Scaling (FIFO_DEPTH_LOG2=4, SYNC_STAGES=3, 15-Beat Burst)...");
        stall_cycles_seen = 0;
        ack_cnt           = 0;
        @(posedge clk_fab);
        deep_cyc <= 1'b1;
        deep_we  <= 1'b1;
        deep_adr <= 2'h2;
        for (int beat = 1; beat <= 15; beat++) begin
            deep_stb  <= 1'b1;
            deep_wdat <= DATA_W'(beat);
            @(posedge clk_fab);
            if (deep_ack) ack_cnt++;
            while (deep_stall) begin
                stall_cycles_seen++;
                @(posedge clk_fab);
                if (deep_ack) ack_cnt++;
            end
        end
        deep_stb <= 1'b0;
        deep_we  <= 1'b0;
        while (ack_cnt < 15) begin
            @(posedge clk_fab);
            if (deep_ack) ack_cnt++;
        end
        deep_cyc <= 1'b0;

        @(posedge clk_fab);
        deep_cyc <= 1'b1;
        deep_stb <= 1'b1;
        deep_we  <= 1'b0;
        deep_adr <= 2'h2;
        do begin
            @(posedge clk_fab);
        end while (deep_stall);
        deep_stb <= 1'b0;
        while (!(deep_ack || deep_err)) begin
            @(posedge clk_fab);
        end
        rval = deep_rdat;
        deep_cyc <= 1'b0;

        if ((stall_cycles_seen != 0) || (rval !== 4'd15)) begin
            $display("  [FAIL] Suite 4b: stalls=%0d, chg_cnt=%0d (exp 0, 15)", stall_cycles_seen, rval);
            test_errors++;
        end else begin
            $display("  [PASS] Suite 4b: 15-beat write burst on 16-entry FIFO (SYNC_STAGES=3) had 0 stalls and chg_cnt=15.");
        end

        $display("----------------------------------------------------------------------");
        if ((test_errors == 0) && (protocol_errors == 0)) begin
            $display(" PART 1 PASSED (test_errors=0, protocol_errors=0)");
        end else begin
            $display(" PART 1 FAILED (test_errors=%0d, protocol_errors=%0d)", test_errors, protocol_errors);
        end
        $display("----------------------------------------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire

