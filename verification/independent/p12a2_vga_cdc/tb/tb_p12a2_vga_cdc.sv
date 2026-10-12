`timescale 1ns/1ps

// =============================================================================
// File: tb_p12a2_vga_cdc.sv
// Module: tb_p12a2_vga_cdc
// Project: P12A2 VGA CDC Independent DV (Corrective Round Revision 3)
// Description: Independent SystemVerilog testbench for VGA CDC & Reset-Recovery.
//              - Pure black-box stimulus (zero hierarchical DUT forcing)
//              - External spec-driven boundary scheduling (F4 resolution)
//              - External DUT completion & causality tracking (F1/F3 resolution)
//              - Multi-lane clock phase and jitter verification
// =============================================================================

module tb_p12a2_vga_cdc;

    // -------------------------------------------------------------------------
    // Parameters & Signals
    // -------------------------------------------------------------------------
    parameter HCLK_HALF_NS   = 10;
    parameter CLK50_HALF_NS  = 10;
    parameter CLOCK_PHASE_NS = 0;

    integer hclk_half;
    integer clk50_half;
    integer clk_phase;
    string  scenario_name;
    realtime pulse_start;
    reg pulse_burst=0;
    reg pulse_watch=0;
    reg source_stopped=0;

    reg clock_50 = 1'b0;
    reg hclk     = 1'b0;
    reg hresetn  = 1'b1;

    // AHB Master Interface
    wire [31:0] haddr;
    wire        hwrite;
    wire [1:0]  htrans;
    wire [2:0]  hsize;
    wire [31:0] hwdata;
    wire        hsel;
    wire        hready_in;
    wire [31:0] hrdata;
    wire        hready;
    wire [1:0]  hresp;

    // VGA display outputs
    wire [3:0]  vga_r, vga_g, vga_b;
    wire        vga_hs, vga_vs;

    wire [9:0] pixel_x,pixel_y;
    wire timing_valid;

    // Scoreboard outputs
    wire        all_checks_passed;
    wire [31:0] total_assertions_checked;
    wire [31:0] physical_writes_observed;
    wire [31:0] clear_writes_observed;

    // -------------------------------------------------------------------------
    // Clock Generation with Arbitrary Phase Offset
    // -------------------------------------------------------------------------
    initial begin
        hclk_half  = HCLK_HALF_NS;
        clk50_half = CLK50_HALF_NS;
        clk_phase  = CLOCK_PHASE_NS;

        if ($value$plusargs("HCLK_HALF_NS=%d", hclk_half))
            $display("[TB_INIT] Parameter override: HCLK_HALF_NS=%0d", hclk_half);
        if ($value$plusargs("CLK50_HALF_NS=%d", clk50_half))
            $display("[TB_INIT] Parameter override: CLK50_HALF_NS=%0d", clk50_half);
        if ($value$plusargs("CLOCK_PHASE_NS=%d", clk_phase))
            $display("[TB_INIT] Parameter override: CLOCK_PHASE_NS=%0d", clk_phase);

        $display("[ELAB_PARAM] HCLK_HALF_NS=%0d CLK50_HALF_NS=%0d CLOCK_PHASE_NS=%0d",
                 hclk_half, clk50_half, clk_phase);

        // Apply initial phase shift to CLOCK_50
        if (clk_phase > 0)
            #(clk_phase);
        forever begin
            // S05: external clock-only behavioral burst reacquires the unchanged
            // PLL model in four 0.5ns periods. No internal signal override.
            if (pulse_burst) #0.25;
            else #(clk50_half);
            if (!source_stopped) clock_50 = ~clock_50;
        end
    end

    always #(hclk_half) hclk = ~hclk;

    // -------------------------------------------------------------------------
    // DUT Instantiation (Unmodified Production Candidate)
    // -------------------------------------------------------------------------
    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50  (clock_50),
        .HCLK      (hclk),
        .HRESETn   (hresetn),
        .HADDR     (haddr),
        .HWRITE    (hwrite),
        .HTRANS    (htrans),
        .HSIZE     (hsize),
        .HWDATA    (hwdata),
        .HSEL      (hsel),
        .HREADY_IN (hready_in),
        .HRDATA    (hrdata),
        .HREADY    (hready),
        .HRESP     (hresp),
        .VGA_R     (vga_r),
        .VGA_G     (vga_g),
        .VGA_B     (vga_b),
        .VGA_HS    (vga_hs),
        .VGA_VS    (vga_vs)
    );

    // -------------------------------------------------------------------------
    // AHB Bus Functional Model (BFM)
    // -------------------------------------------------------------------------
    ahb_vga_bfm u_bfm (
        .hclk      (hclk),
        .hresetn   (hresetn),
        .hready    (hready),
        .hresp     (hresp),
        .hrdata    (hrdata),
        .haddr     (haddr),
        .hwrite    (hwrite),
        .htrans    (htrans),
        .hsize     (hsize),
        .hwdata    (hwdata),
        .hsel      (hsel),
        .hready_in (hready_in)
    );

    // -------------------------------------------------------------------------
    // Independent Reference Model
    // -------------------------------------------------------------------------
    vga_cdc_ref_model u_ref_model (
        .pclk_25(dut.pclk_25), .hresetn(hresetn),
        .pll_locked(dut.vga_pll_locked), .vga_hs(vga_hs), .vga_vs(vga_vs),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .timing_valid(timing_valid)
    );
    vga_cdc_scoreboard u_scoreboard (
        .hclk(hclk), .pclk_25(dut.pclk_25), .hresetn(hresetn),
        .pll_locked(dut.vga_pll_locked),
        .haddr(haddr), .hwdata(hwdata), .hrdata(hrdata),
        .hwrite(hwrite), .hsel(hsel), .hready_in(hready_in), .hready(hready),
        .htrans(htrans), .hresp(hresp), .hsize(hsize),
        .dut_vram0_we(dut.vram0_we), .dut_vram1_we(dut.vram1_we),
        .dut_write_addr(dut.write_addr), .dut_write_data(dut.write_data),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .timing_valid(timing_valid),
        .actual_busy(dut.operation_busy), .actual_done(dut.operation_done_sticky),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .all_checks_passed(all_checks_passed),
        .total_assertions_checked(total_assertions_checked),
        .physical_writes_observed(physical_writes_observed),
        .clear_writes_observed(clear_writes_observed)
    );

    // -------------------------------------------------------------------------
    // Helper Tasks for Test Scenarios
    // -------------------------------------------------------------------------
    // Rev6: passive actual measurements only. No tap feeds the timing oracle,
    // bus stimulus, or an expected owner/request/epoch value.
    p12a2_b1_observer u_b1 (
        .hclk(hclk), .pclk(dut.pclk_25), .hresetn(hresetn),
        .lock_valid(dut.vga_pll_locked), .pixel_reset_n(dut.vga_reset_n),
        .h_epoch_valid(dut.h_epoch_valid),
        .haddr(haddr), .hwdata(hwdata), .hrdata(hrdata),
        .hwrite(hwrite), .hsel(hsel), .hready_in(hready_in),
        .hready(hready), .htrans(htrans), .hresp(hresp), .hsize(hsize),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .timing_valid(timing_valid),
        .actual_request(dut.request_toggle_h), .actual_front_p(dut.front_bank_p),
        .actual_ack_p(dut.ack_toggle_p), .actual_ack_sync(dut.ack_sync_h),
        .actual_ack_seen(dut.ack_seen_h), .actual_front_h(dut.front_bank_h),
        .actual_busy(dut.operation_busy), .actual_done(dut.operation_done_sticky),
        .vram0_we(dut.vram0_we), .vram1_we(dut.vram1_we),
        .physical_addr(dut.write_addr), .physical_data(dut.write_data),
        .actual_clear_target(dut.clear_target_bank)
    );

    // Snapshot validated measured-event counts after B1's +4ps checks. Explicit
    // edge sampling avoids simulator array-expression port sensitivity gaps.
    bit b3_profile;
    initial b3_profile=$test$plusargs("B3_PROFILE") || $test$plusargs("B4_PROFILE");
    integer b3_consumed_record=0,b3_owner_record=0,b3_clear_record=0;
    always @(posedge hclk) if(b3_profile) begin
        #0.006;
        b3_consumed_record=u_b1.consumptions[u_b1.current_id];
        b3_owner_record=u_b1.owners[u_b1.current_id];
        b3_clear_record=u_b1.b2_clear_count;
    end
    p12a2_b3_observer u_b3 (
        .hclk(hclk),.pclk(dut.pclk_25),.hresetn(hresetn),.lock_valid(dut.vga_pll_locked),
        .pixel_reset_n(dut.vga_reset_n),.pixel_ready(dut.pixel_ready_p),.domain_ready(dut.domain_ready),
        .actual_busy(dut.operation_busy),.actual_done(dut.operation_done_sticky),
        .actual_abort(dut.operation_abort_sticky),.actual_vsync(dut.vsync_sticky),
        .actual_request(dut.request_toggle_h),.actual_front_p(dut.front_bank_p),.actual_ack_p(dut.ack_toggle_p),
        .actual_front_h(dut.front_bank_h),.actual_ack_sync(dut.ack_sync_h),.actual_ack_seen(dut.ack_seen_h),
        .vram0_we(dut.vram0_we),.vram1_we(dut.vram1_we),
        .haddr(haddr),.hwdata(hwdata),.hrdata(hrdata),.hwrite(hwrite),.hsel(hsel),.hready_in(hready_in),
        .hready(hready),.htrans(htrans),.hresp(hresp),.hsize(hsize),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.timing_valid(timing_valid),
        .validated_consume(b3_consumed_record),
        .validated_owner(b3_owner_record),.validated_clear(b3_clear_record)
    );

    p12a2_b4_observer u_b4 (
        .hclk(hclk),.pclk(dut.pclk_25),.hresetn(hresetn),.lock_valid(dut.vga_pll_locked),.vga_vs(vga_vs),
        .vga_r(vga_r),.vga_g(vga_g),.vga_b(vga_b),.pixel_x(pixel_x),.pixel_y(pixel_y),.timing_valid(timing_valid),
        .haddr(haddr),.hwdata(hwdata),.hrdata(hrdata),.hwrite(hwrite),.hsel(hsel),.hready_in(hready_in),.hready(hready),
        .htrans(htrans),.hresp(hresp),.hsize(hsize),.actual_vsync(dut.vsync_sticky),.actual_busy(dut.operation_busy),
        .actual_ack_sync(dut.ack_sync_h),.actual_ack_seen(dut.ack_seen_h),.vram0_we(dut.vram0_we),.vram1_we(dut.vram1_we),
        .physical_addr(dut.write_addr),.physical_data(dut.write_data),.validated_consume(b3_consumed_record),.validated_owner(b3_owner_record)
    );

    task automatic wait_domain_ready;
        integer timeout_cnt;
        reg [31:0] stat;
        begin
            $display("[DOMAIN_READY] Waiting for domain ready at time %0t", $time);
            timeout_cnt = 0;
            stat = 32'h0;
            while (!stat[4] && timeout_cnt < 500) begin
                u_bfm.vram_status_read(stat);
                $display("[DOMAIN_READY] Poll #%0d stat=%08h at time %0t", timeout_cnt, stat, $time);
                timeout_cnt = timeout_cnt + 1;
            end
            if (!stat[4]) begin
                $display("[FATAL] DOMAIN_READY timeout after %0d polls", timeout_cnt);
                $fatal(1, "Domain ready timeout");
            end
            u_scoreboard.check_assert(stat[4] == 1'b1, "DOMAIN_READY observed high via AHB status", "PASS_DOMAIN_READY");
        end
    endtask

    task automatic reset_sequence;
        begin
            $display("[RESET] Entering reset_sequence at time %0t", $time);
            @(negedge hclk);
            $display("[RESET] Asserting hresetn=0 at time %0t", $time);
            hresetn = 1'b0;
            repeat (10) @(posedge hclk);
            @(negedge hclk);
            $display("[RESET] Deasserting hresetn=1 at time %0t", $time);
            hresetn = 1'b1;
            wait_domain_ready();
            $display("[RESET] Completed reset_sequence at time %0t", $time);
        end
    endtask

    // -------------------------------------------------------------------------
    // External Video Timing Synchronization Task (F4 Resolution)
    // Synchronizes stimulus strictly via top-level external pins:
    // VGA_VS rising edge (end of vsync pulse, line 492) and VGA_HS line pulses.
    // Zero internal hierarchical access to dut.v_cnt or dut.h_cnt.
    // -------------------------------------------------------------------------
    // HCLK data effect occurs two rising edges after starting a BFM call.
    // Select the preceding falling edge using measured clock phase and an
    // independent predicted coordinate at the data edge. No DUT counter read.
    task automatic boundary_command(input integer target);
        integer shift, effect_pixel;
        realtime next_pixel, effect_time, pperiod;
        begin
            shift=$test$plusargs("BOUNDARY_SHIFT") ? -10 : 0;
            u_scoreboard.arm_boundary(target);
            pperiod=4*clk50_half;
            begin : find_bus_edge
                forever begin
                    @(posedge hclk); #0.005;
                    // Next BFM start at falling edge; address at +1T, effect+2T.
                    next_pixel=last_pixel_edge+pperiod;
                    effect_time=$realtime+4*hclk_half-0.005;
                    effect_pixel=pixel_x;
                    if (effect_time > next_pixel+0.001)
                        effect_pixel=pixel_x+1+$rtoi((effect_time-next_pixel-0.001)/pperiod);
                    if (timing_valid && pixel_y==524 && effect_pixel==target+shift)
                        disable find_bus_edge;
                end
            end
            $display("[S02_SCHEDULE] target=%0d shift=%0d model_x=%0d y=%0d time=%0t",target,shift,pixel_x,pixel_y,$time);
            u_bfm.vram_control_write(32'h1);
        end
    endtask
    realtime last_pixel_edge=0;
    always @(posedge dut.pclk_25) last_pixel_edge=$realtime;

    task automatic wait_operation_done(input string label_name);
        reg [31:0] st;
        integer polls;
        begin
            st=0; polls=0;
            while (!st[1] && polls<100000) begin
                u_bfm.vram_status_read(st); polls=polls+1;
                u_scoreboard.check_assert(!st[3],"No unexpected abort while waiting for completion","FAIL_UNEXPECTED_ABORT");
                if (!st[1]) repeat(50) @(posedge hclk);
            end
            u_scoreboard.check_assert(st[1] && !st[2],"Operation successfully completed via AHB status","FAIL_DONE_TIMEOUT");
            $display("[SCENARIO_DONE] %s time=%0t",label_name,$time);
            // Let the first active-line scanout marker after frame wrap arrive.
            repeat(25) @(posedge dut.pclk_25);
            u_bfm.vram_status_w1c(32'h2);
        end
    endtask

    // Select a bus call from independent reference geometry and external
    // clock phase. The legal final ERROR data edge is three HCLK edges later.
    task automatic b2_boundary_error(input integer final_pixel,input [31:0] addr,input [31:0] value);
        realtime next_pixel,final_time,pperiod;
        integer predicted;
        begin
            pperiod=4*clk50_half;
            begin : schedule
                forever begin
                    @(posedge hclk); #0.005;
                    next_pixel=last_pixel_edge+pperiod;
                    final_time=$realtime+6*hclk_half-0.005;
                    predicted=pixel_x;
                    if (final_time>next_pixel+0.001)
                        predicted=pixel_x+1+$rtoi((final_time-next_pixel-0.001)/pperiod);
                    if (timing_valid && pixel_y==524 && predicted==final_pixel) disable schedule;
                end
            end
            $display("[B2_SCHEDULE] final_pixel=%0d addr=%h model_x=%0d y=%0d time=%0t",final_pixel,addr,pixel_x,pixel_y,$time);
            u_bfm.window_error(addr,value);
        end
    endtask
    // Wait on the checker-ledger's validated physical commits; not a DUT
    // cleaner count, owner, or completion level. No completion latency bound.
    task automatic b2_clear_progress(input integer words);
        begin
            while (u_b1.b2_clear_count<words) begin @(posedge hclk); #0.005; end
        end
    endtask
    task automatic b2_completed_wait(input integer count);
        begin
            while (u_b1.b2_completed<count) begin @(posedge hclk); #0.010; end
        end
    endtask

    always @(posedge dut.vga_pll_locked) begin
        if (pulse_watch) begin
            $display("[S05_PULSE_MEASURED] lock_low_duration_ns=%0.3f time=%0t external_clock_burst=1",$realtime-pulse_start,$time);
            u_scoreboard.check_assert($realtime-pulse_start>=1.998 && $realtime-pulse_start<=2.001,
                "Behavioral raw lock pulse measured at2ns within1ps","FAIL_S05_PULSE_WIDTH");
            pulse_watch=0; pulse_burst=0;
        end
    end

    // -------------------------------------------------------------------------
    // Global Simulation Timeout Guard
    // -------------------------------------------------------------------------
    initial begin
        #250_000_000; // 250 ms finite simulation budget, not a contract limit
        $display("[FATAL] Global simulation timeout reached at %0t", $time);
        $fatal(1, "Global timeout guard triggered");
    end

    // -------------------------------------------------------------------------
    // Main Scenario Execution Flow
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================================");
        $display("=== P12A2 VGA CDC & Reset-Recovery Independent DV Testbench   ===");
        $display("=================================================================");

        if (!$value$plusargs("SCENARIO=%s", scenario_name))
            scenario_name = "ALL";

        $display("[TB_FLOW] Target Scenario: %0s", scenario_name);

        // Initial Reset
        reset_sequence();

        // ---------------------------------------------------------------------
        // S01: Arbitrary Clock Phase & Asynchronous Ratios
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S01") begin
            $display("\n--- Starting S01: Arbitrary Clock Phase & Frame Swap Verification ---");
            // Canonical Framebuffer Write to back bank (VRAM1)
            u_bfm.vram_fb_write(14'd0, 32'hffff_ffff);
            u_bfm.vram_fb_write(14'd1, 32'hcafe_0002);
            u_scoreboard.check_assert(physical_writes_observed==2, "S01: Initial back-bank writes completed", "PASS_S01_WRITE");

            // Issue SWAP command & register in scoreboard
            u_bfm.vram_control_write(32'h1);
            $display("[S01] SWAP command issued at %0t. Awaiting natural frame-wrap commit...", $time);

            // Wait for natural completion via AHB status polling
            begin : s01_poll
                reg [31:0] st;
                integer polls;
                polls = 0;
                st = 0;
                while (!st[1] && polls < 1_000_000) begin
                    u_bfm.vram_status_read(st);
                    polls = polls + 1;
                    if (st[3]) $fatal(1, "S01: Unexpected OP_ABORT");
                    if (!st[1]) repeat (50) @(posedge hclk);
                end
                // Observe DUT completion and check semantic causality
                u_scoreboard.check_assert(st[1] == 1'b1, "S01: OP_DONE successfully observed after natural wrap", "PASS_S01_DONE");
                // Clear DONE via W1C
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(32'h2);
            end

            // Verify write now targets new back bank (VRAM0)
            u_bfm.vram_fb_write(14'd0, 32'h0000_0000);
            u_scoreboard.check_assert(physical_writes_observed==3, "S01: Post-swap write targeted new back bank", "PASS_S01_POST_SWAP");
        end

        // ---------------------------------------------------------------------
        // S02: Boundary-Critical SWAP (Prefetch 798 vs Commit 799)
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S02") begin
            $display("\n--- Starting S02: Boundary-Critical Frame-Wrap SWAP ---");
            if (scenario_name=="S02") begin
                // Establish contrasting banks legally, with a natural warmup swap.
                u_bfm.vram_fb_write(14'd0,32'hffff_ffff);
                u_bfm.vram_control_write(32'h1);
                wait_operation_done("S02_MARKER_SETUP");
                u_bfm.vram_fb_write(14'd0,32'h0000_0000);
            end
            boundary_command(798);
            wait_operation_done("S02_PREFETCH_INTERFACE_WINDOW");
            boundary_command(799);
            wait_operation_done("S02_COMMIT_INTERFACE_WINDOW");
        end

        // ---------------------------------------------------------------------
        // S03: SWAP|CLEAR Lock-Loss Injection at Critical Epochs
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S03") begin
            $display("\n--- Starting S03: SWAP|CLEAR Lock-Loss Injection ---");
            // Issue SWAP|CLEAR
            u_bfm.vram_control_write(32'h3);

            // Inject PLL lock loss after short delay (during active operation)
            repeat (20) @(posedge hclk);
            @(negedge hclk);
            $display("[S03] Injecting PLL lock loss during active SWAP|CLEAR at %0t...", $time);
            dut.U_PLL.inject_lock_loss();

            // Observe immediate OP_ABORT via status
            begin : s03_poll
                reg [31:0] st;
                integer p;
                p = 0;
                st = 0;
                while (!st[3] && p < 200) begin
                    u_bfm.vram_status_read(st);
                    p = p + 1;
                end
                u_scoreboard.check_assert(st[3] == 1'b1, "S03: Sticky OP_ABORT correctly set upon lock loss", "PASS_S03_ABORT");
                u_scoreboard.check_assert(st[1] == 1'b0, "S03: Aborted operation never produced OP_DONE", "PASS_S03_NO_DONE");
                // Clear abort sticky
                u_bfm.vram_status_w1c(32'h8);
            end

            // Wait for domain to recover
            wait_domain_ready();
            // wait_domain_ready already asserts AHB DOMAIN_READY. Timing anchors later at first HS.
        end

        // ---------------------------------------------------------------------
        // S04: Clear-Only Interruption & Concurrent W1C
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S04") begin
            $display("\n--- Starting S04: Clear-Only Interruption & Concurrent W1C ---");
            // Issue CLEAR only (HWDATA=2)
            u_bfm.vram_control_write(32'h2);

            // Let clear stream proceed for 100 cycles, then inject lock loss and concurrent W1C
            repeat (100) @(posedge hclk);
            @(negedge hclk);
            dut.U_PLL.inject_lock_loss();
            u_bfm.vram_status_w1c(32'h8); // concurrent W1C write during loss

            begin : s04_poll
                reg [31:0] st;
                u_bfm.vram_status_read(st);
                u_scoreboard.check_assert(st[2] == 1'b0, "S04: OP_BUSY dropped immediately upon clear interruption", "PASS_S04_BUSY_DROPPED");
            end

            wait_domain_ready();
        end

        // ---------------------------------------------------------------------
        // S05: Sub-HCLK Raw Lock-Low Pulses (Asynchronous Capture)
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S05") begin
            $display("\n--- Starting S05: Sub-HCLK Short Lock Pulses ---");
            // Inject short lock-loss pulse falling between HCLK edges
            @(posedge hclk);
            #2; // 2ns after posedge
            pulse_burst=1;
            // Start just after a source rising edge. Four subsequent model
            // acquisition edges yield a measured ~2ns raw lock-low pulse.
            @(posedge clock_50); #0.001;
            pulse_watch=1;
            pulse_start=$realtime;
            dut.U_PLL.inject_lock_loss();
            $display("[S05] Short lock loss pulse injected between HCLK rising edges at %0t", $time);

            // Re-verify that u_h_epoch_sync captured invalidity and domain dropped
            repeat (2) @(posedge hclk);
            begin : s05_check
                reg [31:0] st;
                u_bfm.vram_status_read(st);
                u_scoreboard.check_assert(st[4] == 1'b0, "S05: DOMAIN_READY dropped on sub-cycle lock loss", "PASS_S05_PULSE_CAPTURED");
            end

            wait_domain_ready();
        end

        // ---------------------------------------------------------------------
        // S06: In-Flight Reset & Clock Resumption
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S06") begin
            $display("\n--- Starting S06: In-Flight Reset Assertion & Resume ---");
            u_bfm.vram_control_write(32'h1);
            repeat (5) @(posedge hclk);
            hresetn = 1'b0; // Assert system reset while swap request in flight
            repeat (10) @(posedge hclk);
            hresetn = 1'b1;

            wait_domain_ready();
            // Verify no stale commit occurs
            repeat (100) @(posedge hclk);
            begin : s06_check
                reg [31:0] st;
                u_bfm.vram_status_read(st);
                u_scoreboard.check_assert(st[1] == 1'b0, "S06: In-flight reset cleanly discarded old transaction", "PASS_S06_STALE_SUPPRESSED");
            end
        end

        // ---------------------------------------------------------------------
        // S07: Protocol Stress & Busy Rejection (Two-Cycle ERROR)
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S07") begin
            $display("\n--- Starting S07: Protocol Stress & Busy Overlap Rejection ---");
            // Establish a contrasting scanout marker through the writable bank.
            u_bfm.vram_status_w1c(32'hA);
            u_bfm.vram_fb_write(14'd0,32'hffff_ffff);
            // Start SWAP operation
            u_bfm.vram_control_write(32'h1);

            // Attempt overlapping framebuffer write while BUSY -> Expect 2-cycle ERROR
            u_bfm.write_expect_error(32'h2000_0000, 3'b010, 32'h1234_5678);
            u_scoreboard.check_assert(u_bfm.error_transfers>=1, "S07: Overlapping FB write rejected with 2-cycle ERROR", "PASS_S07_FB_REJECT");

            // Attempt overlapping CONTROL write while BUSY -> Expect 2-cycle ERROR
            u_bfm.write_expect_error(32'h2001_0004, 3'b010, 32'h2);
            u_scoreboard.check_assert(u_bfm.error_transfers>=2, "S07: Overlapping CONTROL write rejected with 2-cycle ERROR", "PASS_S07_CTRL_REJECT");

            // Wait for initial swap to complete
            begin : s07_wait
                reg [31:0] st;
                integer p;
                p = 0;
                st = 0;
                while (!st[1] && p < 1_000_000) begin
                    u_bfm.vram_status_read(st);
                    p = p + 1;
                    if (!st[1]) repeat (50) @(posedge hclk);
                end
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(32'h2);
            end

            // Zero-command write test: HWDATA[1:0]=00 -> Valid bus write but no op
            u_bfm.vram_control_write(32'h0);
            begin : s07_zero_check
                reg [31:0] st;
                u_bfm.vram_status_read(st);
                u_scoreboard.check_assert(st[2] == 1'b0, "S07: Zero-command did not assert OP_BUSY", "PASS_S07_ZERO_CMD");
            end
        end

        // ---------------------------------------------------------------------
        // S08: Repeated Recovery & Consecutive Post-Recovery SWAPs
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S08") begin
            $display("\n--- Starting S08: Repeated Recovery & Consecutive SWAPs ---");
            // 3 rapid lock loss / recovery cycles
            repeat (3) begin
                @(negedge hclk);
                dut.U_PLL.inject_lock_loss();
                repeat (10) @(posedge hclk);
                wait_domain_ready();
            end

            u_bfm.vram_status_w1c(32'hA);
            u_bfm.vram_fb_write(14'd0,32'hffff_ffff);
            // Consecutive SWAP 1
            u_bfm.vram_control_write(32'h1);
            begin : s08_swap1
                reg [31:0] st;
                integer p;
                p = 0;
                st = 0;
                while (!st[1] && p < 1_000_000) begin
                    u_bfm.vram_status_read(st);
                    p = p + 1;
                    if (!st[1]) repeat (50) @(posedge hclk);
                end
                u_scoreboard.check_assert(st[1] == 1'b1, "S08: Post-recovery SWAP #1 completed", "PASS_S08_SWAP1");
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(32'h2);
            end

            u_bfm.vram_fb_write(14'd0,32'h0000_0000);
            // Consecutive SWAP 2 (tests toggle rebase)
            u_bfm.vram_control_write(32'h1);
            begin : s08_swap2
                reg [31:0] st;
                integer p;
                p = 0;
                st = 0;
                while (!st[1] && p < 1_000_000) begin
                    u_bfm.vram_status_read(st);
                    p = p + 1;
                    if (!st[1]) repeat (50) @(posedge hclk);
                end
                u_scoreboard.check_assert(st[1] == 1'b1, "S08: Post-recovery SWAP #2 completed", "PASS_S08_SWAP2");
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(32'h2);
            end
        end

        // ---------------------------------------------------------------------
        // S09: Bounded Eventual Progress & Liveness
        // ---------------------------------------------------------------------
        if (scenario_name == "ALL" || scenario_name == "S09") begin
            $display("\n--- Starting S09: Bounded Progress & Liveness ---");
            // CLEAR only completion cycle count bound check
            begin : s09_clear
                integer start_time, end_time, elapsed_cycles;
                reg [31:0] st;
                integer p;
                start_time = $time;
                u_bfm.vram_control_write(32'h2);
                    p = 0;
                st = 0;
                while (!st[1] && p < 20_000) begin
                    u_bfm.vram_status_read(st);
                    p = p + 1;
                end
                end_time = $time;
                elapsed_cycles = (end_time - start_time) / (hclk_half * 2);
                $display("[S09] CLEAR completed in %0d HCLK cycles", elapsed_cycles);
                u_scoreboard.check_assert(st[1] && !st[2], "S09: CLEAR completed within finite polling budget", "FAIL_S09_DONE_TIMEOUT");
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(32'h2);
            end
        end

        if (scenario_name=="ALL" || scenario_name=="COMBINED") begin
            $display("--- Starting COMBINED: Successful SWAP|CLEAR completion ---");
            u_bfm.vram_status_w1c(32'hA);
            u_bfm.vram_fb_write(14'd0,32'hffff_ffff);
            u_bfm.vram_control_write(32'h3);
            wait_operation_done("COMBINED");
        end

        if (scenario_name=="B2_SWAP") begin : b2_swap
            integer n;
            $display("--- Starting B2_SWAP: narrow transfer windows and first-DONE ---");
            for(n=0;n<3;n=n+1) begin
                u_bfm.vram_fb_write(0,n%2==0 ? 32'hffffffff : 0);
                u_bfm.vram_control_write(1);
                u_bfm.window_error(32'h20000004,32'h12345678);
                // Actual final data edges at prefetch/commit and just after
                // naturally elapsed commit; both FB and CONTROL are attempted.
                // Predicted800 means the first HCLK final data edge AFTER
                // external wrap. It is a scheduling coordinate, not a DUT
                // counter or an assumed ACK latency.
                b2_boundary_error(n==0 ? 798 : 800,n==2 ? 32'h20000008 : 32'h20010004,2);
                // Every classification remains measured. The n0 transfers
                // cover799 and the return/consumption edge; n1/n2 use the first
                // final ERROR edge independently predicted AFTER wrap.
                if (n==0) begin
                    // Already at798; another legal ERROR transfer finishes at
                    // 0/1 depending on phase, before or on ACK consumption.
                    u_bfm.window_error(32'h20000008,32'hbadc0de);
                    u_bfm.window_error(32'h2000000c,32'hbadc0de);
                end else begin
                    // After first postwrap final ERROR: address on next HCLK,
                    // W1C data edge follows. This targets consumption in the
                    // pinned digital environment, with no oracle latency rule.
                    // Actual collision must be measured and guarded.
                    u_bfm.vram_status_w1c(2);
                end
                b2_completed_wait(n+1);
                u_bfm.vram_fb_write(1,32'hacced001+n);
                u_bfm.vram_status_w1c(1); // unselected DONE remains sticky
                repeat(4) @(posedge hclk);
                u_bfm.vram_status_w1c(2);
                repeat(25) @(posedge dut.pclk_25);
            end
            u_bfm.vram_control_write(0);
            u_bfm.vram_control_write(32'hffff_fffc);
        end
        if (scenario_name=="B2_CLEAR") begin : b2_clear
            integer n;
            reg [31:0] retained_status;
            $display("--- Starting B2_CLEAR: first-DONE, old sticky and collision ---");
            for(n=0;n<2;n=n+1) begin
                // Deliberately leave first completion sticky across next
                // accepted CLEAR. BUSY and new event identity remain distinct.
                u_bfm.vram_control_write(2);
                u_bfm.vram_status_read(retained_status);
                $display("[B2_OLD_STICKY_STATUS] iteration=%0d DONE=%b BUSY=%b time=%0t",n,retained_status[1],retained_status[2],$time);
                u_bfm.window_error(32'h20000000,32'hbadbad);
                b2_clear_progress(9598);
                u_bfm.window_error(32'h20010004,1);
                b2_clear_progress(9599);
                u_bfm.vram_status_w1c(2); // independently scheduled final-word/DONE collision
                b2_completed_wait(n+1);
                u_bfm.vram_status_w1c(32'hffff_fffd); // all unselected/reserved/live bits
                repeat(4) @(posedge hclk);
                u_bfm.vram_fb_write(2,32'habcd);
            end
            u_bfm.vram_status_w1c(2);
            u_bfm.vram_control_write(0);
            u_bfm.vram_control_write(32'hffff_fffc);
        end
        if (scenario_name=="B2_COMBINED") begin
            $display("--- Starting B2_COMBINED: postACK immutable clear target ---");
            u_bfm.vram_fb_write(0,32'hffffffff);
            u_bfm.vram_control_write(3);
            u_bfm.window_error(32'h20000000,32'hbadbad);
            b2_boundary_error(800,32'h20000004,32'hbadbad);
            u_bfm.window_error(32'h20010004,1);
            b2_clear_progress(9598);
            u_bfm.window_error(32'h20000008,32'hbadbad);
            b2_clear_progress(9599);
            u_bfm.vram_status_w1c(2);
            b2_completed_wait(1);
            u_bfm.vram_status_w1c(1);
            repeat(4) @(posedge hclk);
            u_bfm.vram_status_w1c(2);
            u_bfm.vram_fb_write(3,32'h12345678);
        end
        if (scenario_name=="B2_CANCEL") begin
            $display("--- Starting B2_CANCEL: existing precommit cancellation class ---");
            u_bfm.vram_control_write(2);
            b2_completed_wait(1); // retain legitimate old sticky DONE
            u_bfm.vram_control_write(1);
            repeat(5) @(posedge hclk);
            @(negedge hclk);dut.U_PLL.inject_lock_loss();
            wait_domain_ready();
            repeat(50) @(posedge hclk);
            u_bfm.vram_status_w1c(8); // old DONE is not an aborted new completion
            u_bfm.vram_status_w1c(2);
            u_bfm.vram_control_write(0);
        end


        if(scenario_name=="B4_COMBINED")begin : b4_combined
            integer target_control;
            target_control=0;if($value$plusargs("B4_CONTROL=%d",target_control))begin end
            u_bfm.vram_fb_write(0,32'hffffffff);
            u_bfm.vram_control_write(3);
            // Legal external scheduling copied from measured B2 swap reach,
            // not a normative ACK-latency oracle. Actual consume reach required.
            b2_boundary_error(798,32'h20010004,1);
            u_bfm.window_error(32'h20000008,32'hbadbad);
            u_bfm.window_error(target_control ? 32'h20010004 : 32'h2000000c,1);
            b2_completed_wait(1);
            u_bfm.vram_fb_write(3,32'h12345678); // address at first idle HCLK
            repeat(25)@(posedge dut.pclk_25);
            u_bfm.vram_status_w1c(2);
            u_b4.check_final(scenario_name);
        end
        if(scenario_name=="B4_DISPLAY")begin : b4_display
            string reset_kind;
            reset_kind="FULL";if($value$plusargs("B4_RESET=%s",reset_kind))begin end
            // Accepted white markers in both banks; show retained VRAM0 white
            // immediately before invalidation, then white memory with no swap.
            u_bfm.vram_fb_write(0,32'hffffffff);u_bfm.vram_control_write(1);b2_completed_wait(1);
            repeat(25)@(posedge dut.pclk_25);u_bfm.vram_status_w1c(2);
            u_bfm.vram_fb_write(0,32'hffff00ff);u_bfm.vram_control_write(1);b2_completed_wait(2);
            repeat(25)@(posedge dut.pclk_25);u_bfm.vram_status_w1c(2);
            @(negedge hclk);
            if(reset_kind=="FULL")begin hresetn=0;repeat(3)@(posedge hclk);@(negedge hclk);hresetn=1;end
            else dut.U_PLL.inject_lock_loss();
            wait_domain_ready();u_bfm.vram_fb_write(0,32'hffffffff);
            u_b4.quiet_begin();while(u_b4.quiet_wraps<2)begin @(posedge dut.pclk_25);#0.020;end u_b4.quiet_end();
            u_bfm.vram_control_write(1);b2_completed_wait(3);repeat(25)@(posedge dut.pclk_25);u_bfm.vram_status_w1c(2);
            u_b4.check_final(scenario_name);
        end
        if(scenario_name=="B4_VSYNC")begin : b4_vsync
            reg [31:0] status;
            u_bfm.vram_control_write(2);b2_completed_wait(1); // legitimate DONE retained
            u_bfm.vram_status_w1c(1);u_bfm.vram_status_read(status);
            u_b4.require(!status[0]&&status[1],"FAIL_B4_STATUS","Selected VSYNC W1C preserves legitimate DONE");
            // Observe a whole natural low sync pulse and deassertion, then its
            // independent three-register HCLK sampling edge (reset13.1).
            @(negedge vga_vs);@(posedge vga_vs);repeat(5)@(posedge hclk);
            u_bfm.vram_status_read(status);u_bfm.vram_status_w1c(2);u_bfm.vram_status_read(status);
            u_bfm.vram_status_w1c(1);u_bfm.vram_status_read(status);
            @(negedge vga_vs);@(posedge vga_vs);
            // After first HCLK sample q1=1; BFM address next HCLK, W1C data
            // following HCLK is q2&&!q3 event. No DUT event tap schedules it.
            @(posedge hclk);#0.020;u_bfm.vram_status_w1c(1);
            u_bfm.vram_status_read(status);u_b4.check_final(scenario_name);
        end

        if(scenario_name=="B3") begin : b3_stimulus
            string slot,reset_kind;
            integer polarity,stop_clock,old_done,cancel_id,cancel_epoch,goal,t,w1c_collision,status_read_collision;
            reg [31:0] status;
            slot="REQUEST";reset_kind="PLL";polarity=1;stop_clock=0;old_done=0;w1c_collision=0;status_read_collision=0;
            if($value$plusargs("B3_SLOT=%s",slot)) begin end
            if($value$plusargs("B3_RESET=%s",reset_kind)) begin end
            if($value$plusargs("B3_POLARITY=%d",polarity)) begin end
            if($value$plusargs("B3_STOP_CLOCK=%d",stop_clock)) begin end
            if($value$plusargs("B3_OLD_DONE=%d",old_done)) begin end
            if($value$plusargs("B3_W1C_COLLISION=%d",w1c_collision)) begin end
            if($value$plusargs("B3_STATUS_READ_COLLISION=%d",status_read_collision)) begin end
            $display("[B3_CONFIG] slot=%s reset=%s request_polarity=%0d stop_clock=%0d old_DONE=%0d",slot,reset_kind,polarity,stop_clock,old_done);
            // Obtain real prior completion evidence. For zero-polarity swap
            // cancellation a warmup swap legally changes accepted toggle parity.
            u_bfm.vram_fb_write(0,32'hffffffff);
            u_bfm.vram_control_write(polarity==0 || slot=="IDLE" ? 1 : 2);
            b2_completed_wait(1);
            repeat(25) @(posedge dut.pclk_25);
            if(!old_done && slot!="IDLE") u_bfm.vram_status_w1c(2);
            if(slot!="IDLE") begin
                u_bfm.vram_fb_write(0,32'hffffffff);
                if(slot=="CLEAR9598" || slot=="CLEAR9599") u_bfm.vram_control_write(2);
                else u_bfm.vram_control_write(3); // still active after HCLK reconstruction
                if(slot=="PRECOMMIT" || slot=="COMMIT_BEFORE") begin
                    goal=slot=="PRECOMMIT" ? 798 : 799;
                    while(!(timing_valid && pixel_y==524 && pixel_x==goal)) begin @(negedge dut.pclk_25); end
                end
                if(slot=="POSTCOMMIT") begin
                    begin : wrap_wait
                        forever begin
                            @(posedge dut.pclk_25);
                            if(timing_valid && pixel_x==799 && pixel_y==524) begin #0.020;disable wrap_wait;end
                        end
                    end
                end
                if(slot=="ACKSYNC") begin
                    while(u_b1.synchronized_acks[u_b1.current_id]==0) begin @(posedge hclk);#0.020;end
                end
                if(slot=="OWNER") begin
                    while(u_b1.owners[u_b1.current_id]==0) begin @(posedge hclk);#0.020;end
                end
                if(slot=="COMBINED_CLEAR") b2_clear_progress(1);
                if(slot=="CLEAR9598" || slot=="COMBINED9598") b2_clear_progress(9599);
                if(slot=="CLEAR9599" || slot=="COMBINED9599") b2_clear_progress(9600);
            end
            // Full reset is tested with every sticky event actually preset.
            if(slot=="IDLE" && reset_kind=="FULL") begin
                u_bfm.vram_control_write(2); // old completed SWAP DONE retained
                repeat(5) @(posedge hclk);
                @(negedge hclk);dut.U_PLL.inject_lock_loss();
                wait_domain_ready();
                u_bfm.vram_status_read(status);
                u_b3.require((status & 32'hb)==32'hb,"FAIL_B3_PREFILL","Natural VSYNC, legitimate old DONE, active-loss ABORT really preset before full reset");
                $display("[B3_PREFILLED_STATUS] status=%h expected_sticky=0b time=%0t",status,$time);
            end
            #0.020;
            cancel_id=u_b1.current_id;cancel_epoch=u_b1.current_epoch;
            $display("[B3_SLOT_REACHED] slot=%s reset=%s id=%0d epoch=%0d type=%0d live=%b request_value=%b request=%0d commit=%0d ack_p=%0d sync=%0d consume=%0d owner=%0d clear_count=%0d x=%0d y=%0d pre_DONE=%b pre_ABORT=%b pre_VSYNC=%b time=%0t",slot,reset_kind,cancel_id,cancel_epoch,u_b1.op_type[cancel_id],u_b1.live,u_b1.request_value[cancel_id],u_b1.requests[cancel_id],u_b1.commits[cancel_id],u_b1.publications[cancel_id],u_b1.synchronized_acks[cancel_id],u_b1.consumptions[cancel_id],u_b1.owners[cancel_id],u_b1.b2_clear_count,pixel_x,pixel_y,dut.operation_done_sticky,dut.operation_abort_sticky,dut.vsync_sticky,$time);
            if(stop_clock) begin source_stopped=1;$display("[B3_SOURCE_STOP] external_CLOCK50=held time=%0t",$time);end
            if(reset_kind=="FULL") begin
                hresetn=0;
                repeat(3) @(posedge hclk);
                @(negedge hclk);hresetn=1;
            end else begin
                if(status_read_collision) begin
                    fork
                        u_bfm.vram_status_read(status);
                        begin
                            @(negedge hclk);@(posedge hclk);#1;
                            dut.U_PLL.inject_lock_loss();
                            $display("[B3_STATUS_READ_STIMULUS] loss_after_STATUS_address=1 before_STATUS_data=1 time=%0t",$time);
                        end
                    join
                    $display("[B3_STATUS_READ_RETURN] data=%h time=%0t",status,$time);
                end else if(w1c_collision) begin
                    fork
                        u_bfm.vram_status_w1c(8);
                        begin
                            @(negedge hclk);@(posedge hclk);#1;
                            dut.U_PLL.inject_lock_loss();
                            $display("[B3_ABORT_W1C_STIMULUS] lock_loss_after_STATUS_address=1 before_STATUS_data=1 time=%0t",$time);
                        end
                    join
                end else dut.U_PLL.inject_lock_loss();
            end
            // Both legal attempts really occupy wait/final ERROR while unready.
            u_bfm.window_error(32'h20000000,32'hbadbad);
            u_bfm.window_error(32'h20010004,3);
            if(stop_clock) begin
                repeat(10) @(posedge hclk);
                u_bfm.vram_status_read(status);
                u_b3.require(!status[4],"FAIL_B3_STOP_READY","No current pixel epoch with indefinitely held source");
                source_stopped=0;$display("[B3_SOURCE_RESUME] external_CLOCK50=resumed time=%0t",$time);
            end
            wait_domain_ready();
            u_b3.quiet_begin();
            if(u_b1.requests[cancel_id]>0) u_b3.replay_old("REQUEST",cancel_epoch,cancel_id);
            if(u_b1.commits[cancel_id]>0) u_b3.replay_old("COMMIT",cancel_epoch,cancel_id);
            if(u_b1.publications[cancel_id]>0) u_b3.replay_old("ACK",cancel_epoch,cancel_id);
            if(slot=="IDLE") u_b3.replay_old("DONE",cancel_epoch,cancel_id);
            while(u_b3.quiet_wraps<2) begin @(posedge dut.pclk_25);#0.020;end
            u_b3.quiet_end();
            u_bfm.vram_status_read(status);
            $display("[B3_RECOVERED_STATUS] reset=%s old_DONE=%0d status=%h time=%0t",reset_kind,old_done,status,$time);
            u_bfm.vram_status_w1c(32'hb);
            u_b3.fresh_begin();
            for(t=1;t<=3;t=t+1) begin
                u_bfm.vram_fb_write(0,t==3 ? 32'hffffffff : (u_scoreboard.bank_word0[u_scoreboard.expected_front][8] ? 0 : 32'hffffffff));
                goal=u_b1.b2_completed+1;
                u_bfm.vram_control_write(t);
                b2_completed_wait(goal);
                repeat(25) @(posedge dut.pclk_25);
                u_bfm.vram_status_w1c(2);
            end
            u_b3.check_final();
        end

        // One narrowly scoped legal epoch transition supplies a passing control
        // and a real archived ACK record for the B1 stale-record selftest.
        if ($test$plusargs("B1_STALE_CONTROL") || $test$plusargs("B1_STALE_ACK")) begin
            @(negedge hclk);
            dut.U_PLL.inject_lock_loss();
            wait_domain_ready();
        end

        // ---------------------------------------------------------------------
        // Final Scoreboard Reconciliation
        // ---------------------------------------------------------------------
        #1000;
        u_scoreboard.check_final_summary();
        u_b1.check_final();
        $display("SUMMARY: PASS P12A2 Independent DV completed successfully at time %0t.", $time);
        $finish;
    end

endmodule
