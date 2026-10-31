// ==============================================================================
// Module: tb_part4_standalone_slave
// Description:
//   Part 4 Verification Suite: Standalone wb_b4_cdc stress verification against
//   a multi-cycle pipelined Wishbone B4 slave with random stall injection,
//   interleaved error responses (m_wb_err_i), mid-burst master aborts with
//   queued slave responses, full entry-reservation backpressure, and slave
//   response freeze watchdog recovery.
// ==============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_part4_standalone_slave #(
    parameter int FIFO_DEPTH_LOG2 = 3
);

    localparam int ADDR_W              = 4;
    localparam int DATA_W              = 8;
    localparam int FIFO_DEPTH          = 1 << FIFO_DEPTH_LOG2;
    localparam int GATE_TIMEOUT_CYCLES = 64;
    localparam int RESP_TIMEOUT_CYCLES = 64;

    logic              clk_wb   = 1'b0;
    logic              rst_wb   = 1'b1;
    logic              s_wb_cyc = 1'b0;
    logic              s_wb_stb = 1'b0;
    logic              s_wb_we  = 1'b0;
    logic [ADDR_W-1:0] s_wb_adr = '0;
    logic [DATA_W-1:0] s_wb_dat = '0;
    wire               s_wb_stall;
    wire               s_wb_ack;
    wire               s_wb_err;
    wire  [DATA_W-1:0] s_wb_dat_o;

    logic              clk_slv  = 1'b0;
    logic              rst_slv  = 1'b1;
    wire               m_wb_cyc;
    wire               m_wb_stb;
    wire               m_wb_we;
    wire  [ADDR_W-1:0] m_wb_adr;
    wire  [DATA_W-1:0] m_wb_dat;
    logic              m_wb_stall = 1'b0;
    logic              m_wb_ack   = 1'b0;
    logic              m_wb_err   = 1'b0;
    logic [DATA_W-1:0] m_wb_dat_i = '0;

    real wb_half_ns  = 5.0;
    real slv_half_ns = 6.3;

    always #(wb_half_ns)  clk_wb  = ~clk_wb;
    always #(slv_half_ns) clk_slv = ~clk_slv;

    wb_b4_cdc #(
        .ADDR_W              (ADDR_W),
        .DATA_W              (DATA_W),
        .FIFO_DEPTH_LOG2     (FIFO_DEPTH_LOG2),
        .SYNC_STAGES         (2),
        .EN_GATE_TIMEOUT     (1),
        .GATE_TIMEOUT_CYCLES (GATE_TIMEOUT_CYCLES),
        .EN_RESP_TIMEOUT     (1),
        .RESP_TIMEOUT_CYCLES (RESP_TIMEOUT_CYCLES)
    ) u_dut (
        .clk_wb_i     (clk_wb),
        .rst_wb_i     (rst_wb),
        .s_wb_cyc_i   (s_wb_cyc),
        .s_wb_stb_i   (s_wb_stb),
        .s_wb_we_i    (s_wb_we),
        .s_wb_adr_i   (s_wb_adr),
        .s_wb_dat_i   (s_wb_dat),
        .s_wb_stall_o (s_wb_stall),
        .s_wb_ack_o   (s_wb_ack),
        .s_wb_err_o   (s_wb_err),
        .s_wb_dat_o   (s_wb_dat_o),

        .clk_slv_i    (clk_slv),
        .rst_slv_i    (rst_slv),
        .m_wb_cyc_o   (m_wb_cyc),
        .m_wb_stb_o   (m_wb_stb),
        .m_wb_we_o    (m_wb_we),
        .m_wb_adr_o   (m_wb_adr),
        .m_wb_dat_o   (m_wb_dat),
        .m_wb_stall_i (m_wb_stall),
        .m_wb_ack_i   (m_wb_ack),
        .m_wb_err_i   (m_wb_err),
        .m_wb_dat_i   (m_wb_dat_i)
    );

    // --------------------------------------------------------------------------
    // Configurable Multi-Cycle Pipelined Slave Model with Queue, Stall & Error
    // --------------------------------------------------------------------------
    localparam int SLV_Q_DEPTH = 32;
    logic              slv_q_we   [0:SLV_Q_DEPTH-1];
    logic [ADDR_W-1:0] slv_q_adr  [0:SLV_Q_DEPTH-1];
    logic [DATA_W-1:0] slv_q_dat  [0:SLV_Q_DEPTH-1];
    int                slv_q_wait [0:SLV_Q_DEPTH-1];
    int                slv_q_head = 0;
    int                slv_q_tail = 0;
    int                slv_q_cnt  = 0;

    logic [DATA_W-1:0] slv_mem [0:(1<<ADDR_W)-1];

    int                slv_stall_prob    = 40;
    int                slv_min_lat       = 1;
    int                slv_max_lat       = 6;
    bit                slv_err_on_f      = 1'b1;
    bit                slv_freeze_ack    = 1'b0;
    int                max_inflight_seen = 0;

    int unsigned       rng_slv = 32'hCAFE_1234;
    function automatic int unsigned next_rng_slv();
        rng_slv = (rng_slv << 13) ^ rng_slv;
        rng_slv = (rng_slv >> 17) ^ rng_slv;
        rng_slv = (rng_slv << 5)  ^ rng_slv;
        return rng_slv;
    endfunction

    // Check Slave-Side Wishbone B4 Protocol Invariants
    logic              prev_slv_stalled = 1'b0;
    logic              prev_m_we        = 1'b0;
    logic [ADDR_W-1:0] prev_m_adr       = '0;
    logic [DATA_W-1:0] prev_m_dat       = '0;
    int                protocol_errors  = 0;
    int                test_errors      = 0;
    int                slv_idx;

    always @(posedge clk_slv) begin
        if (rst_slv || (!m_wb_cyc && (slv_q_cnt > 0))) begin
            prev_slv_stalled <= 1'b0;
            slv_q_head       <= 0;
            slv_q_tail       <= 0;
            slv_q_cnt        <= 0;
            m_wb_ack         <= 1'b0;
            m_wb_err         <= 1'b0;
            m_wb_dat_i       <= '0;
            m_wb_stall       <= 1'b0;
        end else begin
            if (int'(u_dut.slv_inflight_cnt_q) > max_inflight_seen) begin
                max_inflight_seen = int'(u_dut.slv_inflight_cnt_q);
            end

            // Protocol check: if stalled on previous cycle, STB and payload must hold
            if (prev_slv_stalled) begin
                if (!m_wb_cyc || !m_wb_stb) begin
                    $display("[SLV-PROTO-ERR] m_wb_cyc/stb dropped while m_wb_stall_i=1 at %0t", $time);
                    protocol_errors++;
                end
                if ((m_wb_we !== prev_m_we) || (m_wb_adr !== prev_m_adr) || (m_wb_dat !== prev_m_dat)) begin
                    $display("[SLV-PROTO-ERR] m_wb payload changed while m_wb_stall_i=1 at %0t", $time);
                    protocol_errors++;
                end
            end

            prev_slv_stalled <= m_wb_cyc && m_wb_stb && m_wb_stall;
            prev_m_we        <= m_wb_we;
            prev_m_adr       <= m_wb_adr;
            prev_m_dat       <= m_wb_dat;

            // Default response signals low
            m_wb_ack   <= 1'b0;
            m_wb_err   <= 1'b0;
            m_wb_dat_i <= '0;

            // Decrement wait timers for queued requests
            for (int i = 0; i < slv_q_cnt; i++) begin
                slv_idx = (slv_q_head + i) % SLV_Q_DEPTH;
                if (slv_q_wait[slv_idx] > 0) begin
                    slv_q_wait[slv_idx] = slv_q_wait[slv_idx] - 1;
                end
            end

            // Pop head of queue if ready and m_wb_cyc is high
            if (!slv_freeze_ack && (slv_q_cnt > 0) && (slv_q_wait[slv_q_head] == 0) && m_wb_cyc) begin
                if (slv_err_on_f && (slv_q_adr[slv_q_head] == 4'hF)) begin
                    m_wb_err   <= 1'b1;
                    m_wb_dat_i <= 8'hEE;
                end else begin
                    m_wb_ack   <= 1'b1;
                    if (slv_q_we[slv_q_head]) begin
                        slv_mem[slv_q_adr[slv_q_head]] <= slv_q_dat[slv_q_head];
                        m_wb_dat_i <= '0;
                    end else begin
                        m_wb_dat_i <= slv_mem[slv_q_adr[slv_q_head]];
                    end
                end
                slv_q_head = (slv_q_head + 1) % SLV_Q_DEPTH;
                slv_q_cnt  = slv_q_cnt - 1;
            end

            // Accept incoming request if not stalled
            if (m_wb_cyc && m_wb_stb && !m_wb_stall) begin
                slv_q_we[slv_q_tail]   = m_wb_we;
                slv_q_adr[slv_q_tail]  = m_wb_adr;
                slv_q_dat[slv_q_tail]  = m_wb_dat;
                slv_q_wait[slv_q_tail] = slv_min_lat + (next_rng_slv() % (slv_max_lat - slv_min_lat + 1));
                slv_q_tail             = (slv_q_tail + 1) % SLV_Q_DEPTH;
                slv_q_cnt              = slv_q_cnt + 1;
            end

            // Random stall generation for next cycle
            m_wb_stall <= ((next_rng_slv() % 100) < slv_stall_prob);
        end
    end

    // Master-side protocol monitor
    always @(posedge clk_wb) begin
        if (!rst_wb) begin
            if (s_wb_ack && s_wb_err) begin
                $display("[MST-PROTO-ERR] Simultaneous ACK and ERR at %0t", $time);
                protocol_errors++;
            end
            if (!s_wb_cyc && (s_wb_ack || s_wb_err)) begin
                $display("[MST-PROTO-ERR] ACK/ERR while s_wb_cyc=0 at %0t", $time);
                protocol_errors++;
            end
        end
    end

    // --------------------------------------------------------------------------
    // Test Tasks & Suites
    // --------------------------------------------------------------------------
    task automatic wait_for_bridge_ready();
        int timeout;
        timeout = 0;
        while (s_wb_stall && (timeout < 500)) begin
            @(posedge clk_wb);
            timeout++;
        end
        if (s_wb_stall) begin
            $display("[ERR] Bridge stuck in stall after 500 cycles at %0t!", $time);
            test_errors++;
        end
    endtask

    logic              exp_we  [0:31];
    logic [ADDR_W-1:0] exp_adr [0:31];
    logic [DATA_W-1:0] exp_dat [0:31];
    logic [DATA_W-1:0] sb_mem  [0:15];

    task automatic run_test_a();
        int n_reqs;
        int issued;
        int rcvd;
        int guard;
        $display("[SUITE 13A] Deep Pipelined Burst with Random Slave Stalls & Latency (FIFO_DEPTH=%0d)...", FIFO_DEPTH);
        slv_stall_prob = 50;
        slv_min_lat    = 3;
        slv_max_lat    = 8;

        for (int burst = 0; burst < 20; burst++) begin
            n_reqs = 1 + (burst % (2 * FIFO_DEPTH));
            issued = 0;
            rcvd   = 0;
            guard  = 0;

            for (int k = 0; k < 16; k++) sb_mem[k] = slv_mem[k];

            for (int i = 0; i < n_reqs; i++) begin
                exp_we[i]  = (next_rng_slv() & 1);
                exp_adr[i] = ADDR_W'(next_rng_slv() % 15);
                exp_dat[i] = DATA_W'(next_rng_slv() & 8'hFF);
                if (exp_we[i]) sb_mem[exp_adr[i]] = exp_dat[i];
                else           exp_dat[i] = sb_mem[exp_adr[i]];
            end

            @(posedge clk_wb);
            s_wb_cyc <= 1'b1;
            s_wb_stb <= 1'b1;
            s_wb_we  <= exp_we[0];
            s_wb_adr <= exp_adr[0];
            s_wb_dat <= exp_we[0] ? exp_dat[0] : 8'h00;

            while ((rcvd < n_reqs) && (guard < 2000)) begin
                @(posedge clk_wb);
                guard++;

                if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                    issued++;
                    if (issued < n_reqs) begin
                        s_wb_stb <= 1'b1;
                        s_wb_we  <= exp_we[issued];
                        s_wb_adr <= exp_adr[issued];
                        s_wb_dat <= exp_we[issued] ? exp_dat[issued] : 8'h00;
                    end else begin
                        s_wb_stb <= 1'b0;
                    end
                end

                if (s_wb_ack || s_wb_err) begin
                    if (s_wb_err) begin
                        $display("[ERR] Unexpected s_wb_err in Suite 13A (burst=%0d, rcvd=%0d)", burst, rcvd);
                        test_errors++;
                    end else if (!exp_we[rcvd] && (s_wb_dat_o !== exp_dat[rcvd])) begin
                        $display("[ERR] Read mismatch in Suite 13A: got 0x%02x, exp 0x%02x", s_wb_dat_o, exp_dat[rcvd]);
                        test_errors++;
                    end
                    rcvd++;
                end
            end

            s_wb_cyc <= 1'b0;
            s_wb_stb <= 1'b0;
            @(posedge clk_wb);

            if (rcvd != n_reqs) begin
                $display("[ERR] Timeout in Suite 13A burst %0d (issued=%0d, rcvd=%0d/%0d)", burst, issued, rcvd, n_reqs);
                test_errors++;
            end
        end
        $display("  [PASS] Suite 13A completed (max_inflight_seen=%0d/%0d).", max_inflight_seen, FIFO_DEPTH);
    endtask

    task automatic run_test_b();
        int issued;
        int rcvd;
        int guard;
        bit exp_err;
        logic              req_we  [0:3];
        logic [ADDR_W-1:0] req_adr [0:3];
        logic [DATA_W-1:0] req_dat [0:3];

        $display("[SUITE 13B] Downstream Slave Error Propagation (m_wb_err_i=1 on addr 0xF)...");
        for (int trial = 0; trial < 10; trial++) begin
            issued     = 0;
            rcvd       = 0;
            guard      = 0;
            req_we[0]  = 1'b1; req_adr[0] = 4'h3; req_dat[0] = DATA_W'(8'hA0 + trial);
            req_we[1]  = 1'b0; req_adr[1] = 4'hF; req_dat[1] = 8'h00;
            req_we[2]  = 1'b0; req_adr[2] = 4'h3; req_dat[2] = 8'h00;
            req_we[3]  = 1'b0; req_adr[3] = 4'hF; req_dat[3] = 8'h00;

            @(posedge clk_wb);
            s_wb_cyc <= 1'b1;
            s_wb_stb <= 1'b1;
            s_wb_we  <= req_we[0];
            s_wb_adr <= req_adr[0];
            s_wb_dat <= req_dat[0];

            while ((rcvd < 4) && (guard < 1000)) begin
                @(posedge clk_wb);
                guard++;
                if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                    issued++;
                    if (issued < 4) begin
                        s_wb_stb <= 1'b1;
                        s_wb_we  <= req_we[issued];
                        s_wb_adr <= req_adr[issued];
                        s_wb_dat <= req_dat[issued];
                    end else begin
                        s_wb_stb <= 1'b0;
                    end
                end

                if (s_wb_ack || s_wb_err) begin
                    exp_err = (req_adr[rcvd] == 4'hF);
                    if (s_wb_err !== exp_err) begin
                        $display("[ERR] Suite 13B trial %0d req %0d: s_wb_err=%0b, exp=%0b", trial, rcvd, s_wb_err, exp_err);
                        test_errors++;
                    end
                    if (!exp_err && !req_we[rcvd] && (s_wb_dat_o !== req_dat[0])) begin
                        $display("[ERR] Suite 13B trial %0d req %0d: read 0x%02x, exp 0x%02x", trial, rcvd, s_wb_dat_o, req_dat[0]);
                        test_errors++;
                    end
                    rcvd++;
                end
            end
            s_wb_cyc <= 1'b0;
            s_wb_stb <= 1'b0;
            @(posedge clk_wb);
        end
        $display("  [PASS] Suite 13B completed (10 multi-request bursts with interleaved m_wb_err_i=1).");
    endtask

    task automatic run_test_c();
        int issued;
        bit got_req;
        bit got_resp;
        int guard;
        $display("[SUITE 13C] Mid-Burst Master Abort with Queued Multi-Cycle Slave Responses...");
        slv_min_lat = 5;
        slv_max_lat = 10;
        for (int trial = 0; trial < 10; trial++) begin
            issued = 0;
            @(posedge clk_wb);
            s_wb_cyc <= 1'b1;
            s_wb_stb <= 1'b1;
            s_wb_we  <= 1'b1;
            s_wb_adr <= ADDR_W'(trial % 8);
            s_wb_dat <= DATA_W'(8'h50 + trial);

            while (issued < FIFO_DEPTH) begin
                @(posedge clk_wb);
                if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                    issued++;
                    if (issued < FIFO_DEPTH) begin
                        s_wb_adr <= ADDR_W'((trial + issued) % 8);
                        s_wb_dat <= DATA_W'(8'h50 + trial + issued);
                    end else begin
                        s_wb_stb <= 1'b0;
                    end
                end
            end

            // Abort immediately while requests are still queued in the slow slave
            s_wb_cyc <= 1'b0;
            s_wb_stb <= 1'b0;
            repeat (3 + (trial % 5)) @(posedge clk_wb);

            // Immediately issue a fresh read and verify it gets its own data, not a stale ACK
            s_wb_cyc <= 1'b1;
            s_wb_stb <= 1'b1;
            s_wb_we  <= 1'b0;
            s_wb_adr <= ADDR_W'(trial % 8);
            got_req  = 1'b0;
            got_resp = 1'b0;
            guard    = 0;
            while (!got_resp && (guard < 1000)) begin
                @(posedge clk_wb);
                guard++;
                if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                    s_wb_stb <= 1'b0;
                    got_req  = 1'b1;
                end
                if (s_wb_ack || s_wb_err) begin
                    if (!got_req) begin
                        $display("[ERR] Suite 13C trial %0d: ACK arrived before new request was accepted!", trial);
                        test_errors++;
                    end
                    if (s_wb_err || (s_wb_dat_o !== DATA_W'(8'h50 + trial))) begin
                        $display("[ERR] Suite 13C trial %0d: read 0x%02x (err=%0b), exp 0x%02x",
                                 trial, s_wb_dat_o, s_wb_err, DATA_W'(8'h50 + trial));
                        test_errors++;
                    end
                    got_resp = 1'b1;
                end
            end
            s_wb_cyc <= 1'b0;
            s_wb_stb <= 1'b0;
            @(posedge clk_wb);
        end
        $display("  [PASS] Suite 13C completed (10 aborts with multi-cycle in-flight slave queue).");
    endtask

    task automatic run_test_d();
        int n_reqs;
        int issued;
        int rcvd;
        int guard;
        $display("[SUITE 13D] Full Entry-Reservation Backpressure (slv_inflight=%0d + req_fifo=%0d)...",
                 FIFO_DEPTH, FIFO_DEPTH);
        slv_stall_prob = 0;
        slv_min_lat    = 20;
        slv_max_lat    = 25;
        n_reqs         = 2 * FIFO_DEPTH;
        issued         = 0;
        rcvd           = 0;
        guard          = 0;

        for (int i = 0; i < n_reqs; i++) begin
            exp_we[i]  = 1'b1;
            exp_adr[i] = ADDR_W'(i % 15);
            exp_dat[i] = DATA_W'(8'hC0 + i);
        end

        @(posedge clk_wb);
        s_wb_cyc <= 1'b1;
        s_wb_stb <= 1'b1;
        s_wb_we  <= exp_we[0];
        s_wb_adr <= exp_adr[0];
        s_wb_dat <= exp_dat[0];

        while ((rcvd < n_reqs) && (guard < 2000)) begin
            @(posedge clk_wb);
            guard++;
            if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                issued++;
                if (issued < n_reqs) begin
                    s_wb_stb <= 1'b1;
                    s_wb_we  <= exp_we[issued];
                    s_wb_adr <= exp_adr[issued];
                    s_wb_dat <= exp_dat[issued];
                end else begin
                    s_wb_stb <= 1'b0;
                end
            end
            if (s_wb_ack || s_wb_err) begin
                if (s_wb_err) begin
                    $display("[ERR] Unexpected s_wb_err in Suite 13D at rcvd=%0d", rcvd);
                    test_errors++;
                end
                rcvd++;
            end
        end
        s_wb_cyc <= 1'b0;
        s_wb_stb <= 1'b0;
        @(posedge clk_wb);

        if (max_inflight_seen != FIFO_DEPTH) begin
            $display("[ERR] Expected max_inflight_seen == %0d in Suite 13D, got %0d", FIFO_DEPTH, max_inflight_seen);
            test_errors++;
        end
        $display("  [PASS] Suite 13D completed (max_inflight_seen=%0d/%0d, all %0d beats ACKed).",
                 max_inflight_seen, FIFO_DEPTH, n_reqs);
    endtask

    task automatic run_test_e();
        int issued;
        int err_cnt;
        int guard;
        $display("[SUITE 13E] Slave Response Freeze -> Watchdog Timeout -> m_wb_cyc Abort & Recovery...");
        slv_stall_prob = 0;
        slv_min_lat    = 2;
        slv_max_lat    = 2;
        slv_freeze_ack = 1'b1;
        issued         = 0;
        err_cnt        = 0;
        guard          = 0;

        @(posedge clk_wb);
        s_wb_cyc <= 1'b1;
        s_wb_stb <= 1'b1;
        s_wb_we  <= 1'b1;
        s_wb_adr <= 4'h2;
        s_wb_dat <= 8'h77;

        while ((err_cnt < FIFO_DEPTH) && (guard < 1000)) begin
            @(posedge clk_wb);
            guard++;
            if (s_wb_cyc && s_wb_stb && !s_wb_stall) begin
                issued++;
                if (issued < FIFO_DEPTH) begin
                    s_wb_adr <= ADDR_W'(2 + issued);
                    s_wb_dat <= DATA_W'(8'h77 + issued);
                end else begin
                    s_wb_stb <= 1'b0;
                end
            end
            if (s_wb_err) begin
                err_cnt++;
            end else if (s_wb_ack) begin
                $display("[ERR] Unexpected ACK during frozen slave in Suite 13E!");
                test_errors++;
            end
        end
        s_wb_cyc <= 1'b0;
        s_wb_stb <= 1'b0;
        @(posedge clk_wb);

        if (err_cnt != FIFO_DEPTH) begin
            $display("[ERR] Suite 13E expected %0d watchdog error drains, got %0d", FIFO_DEPTH, err_cnt);
            test_errors++;
        end

        // Unfreeze slave, wait for RDC recovery, and verify clean R/W
        slv_freeze_ack = 1'b0;
        wait_for_bridge_ready();

        @(posedge clk_wb);
        s_wb_cyc <= 1'b1;
        s_wb_stb <= 1'b1;
        s_wb_we  <= 1'b1;
        s_wb_adr <= 4'h2;
        s_wb_dat <= 8'hA5;
        guard = 0;
        while (!s_wb_ack && (guard < 500)) begin
            @(posedge clk_wb);
            guard++;
            if (s_wb_cyc && s_wb_stb && !s_wb_stall) s_wb_stb <= 1'b0;
        end
        s_wb_cyc <= 1'b0;
        @(posedge clk_wb);

        s_wb_cyc <= 1'b1;
        s_wb_stb <= 1'b1;
        s_wb_we  <= 1'b0;
        s_wb_adr <= 4'h2;
        guard = 0;
        while (!s_wb_ack && (guard < 500)) begin
            @(posedge clk_wb);
            guard++;
            if (s_wb_cyc && s_wb_stb && !s_wb_stall) s_wb_stb <= 1'b0;
            if (s_wb_ack && (s_wb_dat_o !== 8'hA5)) begin
                $display("[ERR] Suite 13E post-recovery read mismatch: got 0x%02x, exp 0xA5", s_wb_dat_o);
                test_errors++;
            end
        end
        s_wb_cyc <= 1'b0;
        @(posedge clk_wb);
        $display("  [PASS] Suite 13E completed (frozen slave timed out, drained %0d errs, aborted via !m_wb_cyc, and recovered).",
                 err_cnt);
    endtask

    initial begin
        $display("======================================================================");
        $display(" Part 4: Standalone wb_b4_cdc Multi-Cycle Stalling Slave Stress");
        $display("======================================================================");
        for (int i = 0; i < (1<<ADDR_W); i++) begin
            slv_mem[i] = DATA_W'(i * 17);
        end

        rst_wb  = 1'b1;
        rst_slv = 1'b1;
        repeat (6) @(posedge clk_wb);
        @(negedge clk_wb)  rst_wb  = 1'b0;
        @(negedge clk_slv) rst_slv = 1'b0;
        wait_for_bridge_ready();

        run_test_a();
        run_test_b();
        run_test_c();
        run_test_d();
        run_test_e();

        if ((test_errors == 0) && (protocol_errors == 0)) begin
            $display("----------------------------------------------------------------------");
            $display(" PART 4 PASSED (test_errors=0, protocol_errors=0)");
            $display("----------------------------------------------------------------------");
            $finish;
        end else begin
            $display("----------------------------------------------------------------------");
            $display(" PART 4 FAILED (test_errors=%0d, protocol_errors=%0d)", test_errors, protocol_errors);
            $display("----------------------------------------------------------------------");
            $fatal(1);
        end
    end

endmodule

`default_nettype wire

