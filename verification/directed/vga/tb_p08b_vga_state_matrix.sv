`timescale 1ns/1ps

module tb_p08b_vga_state_matrix;
    integer clock_phase_ns;
    reg clock_50 = 0;
    reg hclk = 0;
    reg hresetn = 0;
    reg [31:0] haddr = 0;
    reg hwrite = 0;
    reg [1:0] htrans = 0;
    reg [2:0] hsize = 3'b010;
    reg [31:0] hwdata = 0;
    reg hsel = 0;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire [3:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs;

    integer assertions_passed;
    integer physical_writes;
    integer swap_commits;
    integer clear_writes;
    integer last_clear_addr;
    reg prior_done;
    reg previous_final_clear_write;

    initial begin
        if (!$value$plusargs("CLOCK_PHASE_NS=%d", clock_phase_ns))
            clock_phase_ns = 0;
        #(clock_phase_ns);
        forever #5 clock_50 = ~clock_50;
    end
    always #5 hclk = ~hclk;

    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50(clock_50), .HCLK(hclk), .HRESETn(hresetn),
        .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans), .HSIZE(hsize),
        .HWDATA(hwdata), .HSEL(hsel), .HREADY_IN(hready),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b),
        .VGA_HS(vga_hs), .VGA_VS(vga_vs)
    );

    always @(posedge hclk) begin
        reg write_at_edge;
        reg [13:0] address_at_edge;
        reg swap_ack_at_edge;
        write_at_edge = dut.vram0_we || dut.vram1_we;
        address_at_edge = dut.write_addr;
        swap_ack_at_edge = dut.swap_ack_event;
        if (write_at_edge) begin
            physical_writes = physical_writes + 1;
            if (dut.vram0_we && dut.vram1_we) $fatal(1, "both banks written");
            if ((dut.vram0_we && dut.front_bank_p == 0) ||
                (dut.vram1_we && dut.front_bank_p == 1))
                $fatal(1, "front bank written addr=%0d", address_at_edge);
        end
        if (dut.clear_we) begin
            clear_writes = clear_writes + 1;
            last_clear_addr = dut.clear_addr;
            if (dut.clear_addr > 14'd9599)
                $fatal(1, "clear outside visible range addr=%0d", dut.clear_addr);
        end
        #1;
        if (!prior_done && dut.operation_done_sticky && !swap_ack_at_edge) begin
            if (!previous_final_clear_write &&
                !(write_at_edge && address_at_edge == 14'd9599))
                $fatal(1, "DONE without final clear commit write=%0d addr=%0d",
                       write_at_edge, address_at_edge);
        end
        prior_done = dut.operation_done_sticky;
        previous_final_clear_write = write_at_edge && address_at_edge == 14'd9599;
    end

    always @(posedge dut.pclk_25) begin
        reg old_front;
        reg wrap_at_edge;
        old_front = dut.front_bank_p;
        wrap_at_edge = dut.frame_wrap_p;
        #1;
        if (hresetn && dut.vga_reset_n && dut.front_bank_p != old_front) begin
            if (!wrap_at_edge) $fatal(1, "front bank changed away from frame boundary");
            swap_commits = swap_commits + 1;
        end
    end

    task automatic pass(input [511:0] label);
        begin
            assertions_passed = assertions_passed + 1;
            $display("ASSERT_PASS %0s", label);
        end
    endtask

    task automatic idle;
        begin
            @(negedge hclk);
            hsel = 0; htrans = 0; hwrite = 0; hsize = 3'b010;
            haddr = 0;
        end
    endtask

    task automatic wait_ready;
        integer n;
        begin
            n = 0;
            while (!dut.domain_ready && n < 300) begin @(posedge hclk); n = n + 1; end
            if (!dut.domain_ready) $fatal(1, "DOMAIN_READY timeout");
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge hclk); hresetn = 0; hsel = 0; htrans = 0;
            repeat (5) @(posedge hclk);
            #1;
            if (dut.vsync_sticky || dut.operation_done_sticky ||
                dut.operation_abort_sticky || dut.operation_busy)
                $fatal(1, "reset did not clear status/operation state");
            @(negedge hclk); hresetn = 1;
            wait_ready();
            prior_done = dut.operation_done_sticky;
        end
    endtask

    task automatic write_ok(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
            haddr = addr; hwdata = data;
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b00) $fatal(1, "expected OKAY addr=%h", addr);
            idle();
            @(posedge hclk); #1;
        end
    endtask

    task automatic write_error(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
            haddr = addr; hwdata = data;
            @(posedge hclk); #1;
            if (hready || hresp != 2'b01) $fatal(1, "missing ERROR wait addr=%h", addr);
            if (dut.vram0_we || dut.vram1_we) $fatal(1, "WE asserted in ERROR wait");
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b01) $fatal(1, "missing ERROR final addr=%h", addr);
            if (dut.vram0_we || dut.vram1_we) $fatal(1, "WE asserted in ERROR final");
            idle();
            @(posedge hclk); #1;
        end
    endtask

    task automatic read_status(output [31:0] value);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 0; hsize = 3'b010;
            haddr = 32'h2001_0000;
            @(posedge hclk); #1;
            if (!hready || hresp != 0) $fatal(1, "status read failed");
            value = hrdata;
            idle();
        end
    endtask

    task automatic force_frame_wrap;
        begin
            wait (dut.pending_swap_p == 1'b1);
            force dut.h_cnt = 10'd799;
            force dut.v_cnt = 10'd524;
            @(posedge dut.pclk_25); #1;
            release dut.h_cnt;
            release dut.v_cnt;
        end
    endtask

    task automatic pulse_frame_without_request;
        begin
            force dut.h_cnt = 10'd799;
            force dut.v_cnt = 10'd524;
            @(posedge dut.pclk_25); #1;
            release dut.h_cnt;
            release dut.v_cnt;
        end
    endtask

    task automatic wait_done;
        integer n;
        begin
            n = 0;
            while (!dut.operation_done_sticky && n < 25000) begin
                @(posedge hclk); n = n + 1;
            end
            if (!dut.operation_done_sticky || dut.operation_busy)
                $fatal(1, "operation completion timeout/busy done=%b busy=%b pending=%b req=%b ack=%b front_h=%b front_p=%b",
                       dut.operation_done_sticky, dut.operation_busy,
                       dut.pending_swap_p, dut.request_toggle_h,
                       dut.ack_toggle_p, dut.front_bank_h, dut.front_bank_p);
        end
    endtask

    task automatic wait_idle;
        integer n;
        begin
            n = 0;
            while (dut.operation_busy && n < 25000) begin
                @(posedge hclk); n = n + 1;
            end
            if (dut.operation_busy) $fatal(1, "operation idle timeout");
        end
    endtask

    task automatic clear_events(input [3:0] mask);
        begin
            write_ok(32'h2001_0000, {28'h0, mask});
        end
    endtask

    task automatic normal_swap;
        integer before_commits;
        begin
            clear_events(4'b1011);
            before_commits = swap_commits;
            write_ok(32'h2001_0004, 32'h1);
            fork
                force_frame_wrap();
                wait_done();
            join
            if (swap_commits != before_commits + 1)
                $fatal(1, "swap completion count before=%0d after=%0d",
                       before_commits, swap_commits);
        end
    endtask

    task automatic inject_loss(input [511:0] label, input integer expect_abort);
        integer writes_before;
        begin
            writes_before = physical_writes;
            dut.U_PLL.inject_lock_loss();
            #1;
            repeat (14) @(posedge hclk);
            if (physical_writes != writes_before)
                $fatal(1, "%0s write continued across PLL loss", label);
            if (dut.operation_busy) $fatal(1, "%0s busy after PLL loss", label);
            if (expect_abort && !dut.operation_abort_sticky)
                $fatal(1, "%0s missing OP_ABORT", label);
            wait_ready();
            if (dut.front_bank_h != 0 || dut.front_bank_p != 0)
                $fatal(1, "%0s ownership not rebased", label);
            if (dut.display_armed_p) $fatal(1, "%0s display not black", label);
            pass(label);
        end
    endtask

    reg [31:0] status;
    integer before_commits;
    integer before_writes;
    reg target_before;
    reg toggle_before;

    initial begin
        assertions_passed = 0;
        physical_writes = 0;
        swap_commits = 0;
        clear_writes = 0;
        last_clear_addr = -1;
        prior_done = 0;
        previous_final_clear_write = 0;
        reset_dut();
        $display("CONFIG phase_ns=%0d hclk_period_ns=10 pclk_period_ns=20", clock_phase_ns);

        // AC-02: normal swap, post-boundary request, rejected repeat, reset pending.
        $display("PROGRESS AC02 normal_swap");
        normal_swap();
        pass("AC02 normal_swap_exact_once_boundary");

        clear_events(4'b0010);
        pulse_frame_without_request();
        before_commits = swap_commits;
        write_ok(32'h2001_0004, 32'h1);
        wait (dut.pending_swap_p);
        repeat (3) @(posedge dut.pclk_25);
        if (swap_commits != before_commits) $fatal(1, "post-boundary request committed early");
        force_frame_wrap();
        wait_done();
        if (swap_commits != before_commits + 1) $fatal(1, "post-boundary swap missing");
        pass("AC02 request_after_boundary");

        clear_events(4'b0010);
        write_ok(32'h2001_0004, 32'h1);
        wait (dut.pending_swap_p);
        toggle_before = dut.request_toggle_h;
        write_error(32'h2001_0004, 32'h1);
        if (dut.request_toggle_h != toggle_before) $fatal(1, "rejected repeat changed request");
        force_frame_wrap(); wait_done();
        pass("AC02 repeated_pending_command_rejected");

        clear_events(4'b0010);
        write_ok(32'h2001_0004, 32'h1);
        wait (dut.pending_swap_p);
        before_commits = swap_commits;
        reset_dut();
        repeat (4) @(posedge dut.pclk_25);
        if (dut.pending_swap_p || dut.operation_busy ||
            dut.request_toggle_h || dut.ack_toggle_p)
            $fatal(1, "reset left CDC/operation state pending");
        if (swap_commits != before_commits) $fatal(1, "reset request committed");
        pass("AC02 reset_during_pending_request");

        // AC-03: clear and command/overlap matrix.
        clear_events(4'b1011);
        before_writes = clear_writes;
        write_ok(32'h2001_0004, 32'h2);
        wait (dut.clear_busy);
        target_before = dut.clear_target_bank;
        toggle_before = dut.request_toggle_h;
        write_error(32'h2001_0004, 32'h2);
        write_error(32'h2001_0004, 32'h1);
        write_error(32'h2000_0010, 32'h9999_0010);
        if (dut.clear_target_bank != target_before || dut.request_toggle_h != toggle_before)
            $fatal(1, "rejected overlap changed operation state");
        wait_done();
        if (clear_writes - before_writes != 9600 || last_clear_addr != 9599)
            $fatal(1, "clear range/count count=%0d last=%0d",
                   clear_writes-before_writes, last_clear_addr);
        pass("AC03 clear_busy_overlap_and_exact_range");

        clear_events(4'b0010);
        before_writes = clear_writes;
        write_ok(32'h2001_0004, 32'h3);
        force_frame_wrap();
        wait (dut.clear_busy);
        if (dut.clear_target_bank == dut.front_bank_h)
            $fatal(1, "combined clear targets displayed front");
        wait_done();
        if (clear_writes - before_writes != 9600)
            $fatal(1, "combined clear count=%0d", clear_writes-before_writes);
        pass("AC03 combined_swap_then_clear");

        clear_events(4'b0010);
        normal_swap();
        normal_swap();
        pass("AC03 sequential_repeated_command");

        clear_events(4'b0010);
        write_ok(32'h2001_0004, 32'h2);
        wait_done();
        clear_events(4'b0010);
        write_ok(32'h2001_0004, 32'h2);
        wait_done();
        pass("AC03 command_after_completion");

        // AC-04: VSYNC sticky set/clear/coincidence/independence/repetition/reset.
        reset_dut();
        if (dut.operation_done_sticky || dut.operation_abort_sticky)
            $fatal(1, "operation sticky status nonzero after reset recovery");
        clear_events(4'b0001);
        pass("AC04 reset_initial_status");
        force dut.vsync_event = 1'b1; @(posedge hclk); #1; release dut.vsync_event;
        if (!dut.vsync_sticky) $fatal(1, "VSYNC event did not set");
        pass("AC04 vsync_event_set");
        clear_events(4'b0001);
        if (dut.vsync_sticky) $fatal(1, "VSYNC W1C did not clear");
        pass("AC04 vsync_w1c_clear");
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2001_0000;
        @(posedge hclk); #1;
        if (!dut.data_valid || dut.data_rejected)
            $fatal(1, "F03-VSYNC address not accepted");
        @(negedge hclk);
        hsel = 0; htrans = 0; hwrite = 0; haddr = 0; hwdata = 32'h1;
        #1;
        if (!dut.accepted_status_write || !hready || hresp != 0)
            $fatal(1, "F03-VSYNC W1C data phase not accepted");
        force dut.vsync_event = 1'b1;
        @(posedge hclk); #1;
        if (!dut.vsync_sticky)
            $fatal(1, "F03-VSYNC exact-edge set dominance failed");
        $display("EDGE_OBS id=F03-VSYNC-COINCIDENT time=%0t accepted=1 event=1 immediate_sticky=%0b", $time, dut.vsync_sticky);
        release dut.vsync_event;
        @(posedge hclk); #1;
        if (!dut.vsync_sticky)
            $fatal(1, "F03-VSYNC sticky unstable after one-cycle event");
        $display("EDGE_OBS id=F03-VSYNC-COINCIDENT time=%0t next_edge_sticky=%0b", $time, dut.vsync_sticky);
        pass("F03-VSYNC-COINCIDENT exact_edge_set_dominance");
        clear_events(4'b0010);
        if (!dut.vsync_sticky) $fatal(1, "other W1C changed VSYNC");
        force dut.vsync_event = 1'b1; repeat (2) @(posedge hclk); #1; release dut.vsync_event;
        clear_events(4'b0001); clear_events(4'b0001);
        if (dut.vsync_sticky) $fatal(1, "repeated VSYNC W1C failed");
        pass("AC04 vsync_independent_repeated");

        // OP_DONE natural set/clear then forced same-cycle hardware completion.
        normal_swap();
        if (!dut.operation_done_sticky) $fatal(1, "OP_DONE not set");
        clear_events(4'b0001);
        if (!dut.operation_done_sticky) $fatal(1, "other W1C changed OP_DONE");
        before_commits = swap_commits;
        write_ok(32'h2001_0004, 32'h1);
        force_frame_wrap();
        wait_idle();
        if (!dut.operation_done_sticky || swap_commits != before_commits + 1)
            $fatal(1, "consecutive OP_DONE event failed");
        clear_events(4'b0010); clear_events(4'b0010);
        if (dut.operation_done_sticky) $fatal(1, "repeated OP_DONE W1C failed");
        write_ok(32'h2001_0004, 32'h1);
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2001_0000;
        @(posedge hclk); #1;
        if (!dut.data_valid || dut.data_rejected)
            $fatal(1, "F03-DONE address not accepted");
        @(negedge hclk);
        hsel = 0; htrans = 0; hwrite = 0; haddr = 0; hwdata = 32'h2;
        #1;
        if (!dut.accepted_status_write || !hready || hresp != 0)
            $fatal(1, "F03-DONE W1C data phase not accepted");
        force dut.swap_ack_event = 1'b1;
        @(posedge hclk); #1;
        if (!dut.operation_done_sticky)
            $fatal(1, "F03-DONE exact-edge set dominance failed");
        $display("EDGE_OBS id=F03-DONE-COINCIDENT time=%0t accepted=1 event=1 immediate_sticky=%0b", $time, dut.operation_done_sticky);
        release dut.swap_ack_event;
        @(posedge hclk); #1;
        if (!dut.operation_done_sticky)
            $fatal(1, "F03-DONE sticky unstable after one-cycle event");
        pass("F03-DONE-COINCIDENT exact_edge_set_dominance");
        reset_dut();

        // OP_ABORT natural set/clear then same-cycle loss/W1C.
        write_ok(32'h2001_0004, 32'h2);
        wait (dut.clear_busy);
        inject_loss("AC05 clear_active_loss", 1);
        if (!dut.operation_abort_sticky) $fatal(1, "OP_ABORT not set");
        clear_events(4'b0010);
        if (!dut.operation_abort_sticky) $fatal(1, "other W1C changed OP_ABORT");
        write_ok(32'h2001_0004, 32'h2);
        wait (dut.clear_busy);
        inject_loss("AC05 consecutive_clear_active_loss", 1);
        if (!dut.operation_abort_sticky) $fatal(1, "consecutive OP_ABORT event failed");
        clear_events(4'b1000); clear_events(4'b1000);
        if (dut.operation_abort_sticky) $fatal(1, "repeated OP_ABORT W1C failed");
        write_ok(32'h2001_0004, 32'h2);
        wait (dut.clear_busy);
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2001_0000;
        @(posedge hclk); #1;
        if (!dut.data_valid || dut.data_rejected)
            $fatal(1, "F03-ABORT address not accepted");
        @(negedge hclk);
        hsel = 0; htrans = 0; hwrite = 0; haddr = 0; hwdata = 32'h8;
        #1;
        if (!dut.accepted_status_write || !hready || hresp != 0)
            $fatal(1, "F03-ABORT W1C data phase not accepted");
        force dut.pll_lock_h2 = 1'b0;
        @(posedge hclk); #1;
        if (!dut.operation_abort_sticky)
            $fatal(1, "F03-ABORT exact-edge set dominance failed");
        $display("EDGE_OBS id=F03-ABORT-COINCIDENT time=%0t accepted=1 event=1 immediate_sticky=%0b", $time, dut.operation_abort_sticky);
        release dut.pll_lock_h2;
        @(posedge hclk); #1;
        if (!dut.operation_abort_sticky)
            $fatal(1, "F03-ABORT sticky unstable after one-cycle event");
        pass("F03-ABORT-COINCIDENT exact_edge_set_dominance");
        reset_dut();

        // AC-05: operation-state PLL-loss matrix and post-recovery operation.
        clear_events(4'b1000);
        inject_loss("AC05 idle_loss", 0);
        normal_swap();
        pass("AC05 idle_recovery_new_operation");
        reset_dut();

        write_ok(32'h2001_0004, 32'h1);
        wait (dut.pending_swap_p);
        inject_loss("AC05 swap_pending_frame_wait_loss", 1);
        normal_swap();
        pass("AC05 swap_pending_recovery_new_operation");
        reset_dut();

        write_ok(32'h2001_0004, 32'h3);
        force_frame_wrap();
        wait (dut.clear_busy);
        inject_loss("AC05 combined_clear_loss", 1);
        normal_swap();
        pass("AC05 combined_recovery_new_operation");
        reset_dut();

        write_ok(32'h2001_0004, 32'h1);
        force_frame_wrap();
        // Pixel acknowledge exists but has not necessarily crossed both HCLK flops.
        if (!dut.operation_busy) $fatal(1, "ack-window operation already completed");
        inject_loss("AC05 cdc_ack_window_loss", 1);
        repeat (10) @(posedge hclk);
        if (dut.operation_busy) $fatal(1, "stale ack restarted operation");
        normal_swap();
        pass("AC05 ack_window_no_duplicate_after_recovery");
        reset_dut();

        dut.U_PLL.inject_lock_loss();
        @(posedge hclk);
        @(negedge hclk); hresetn = 0;
        repeat (3) @(posedge hclk);
        @(negedge hclk); hresetn = 1;
        wait_ready();
        if (dut.operation_busy || dut.front_bank_h != 0 || dut.front_bank_p != 0 ||
            dut.display_armed_p)
            $fatal(1, "near reset/PLL loss recovery state unsafe");
        pass("AC05 reset_near_pll_loss");

        read_status(status);
        $display("OBSERVED phase_ns=%0d assertions=%0d swaps=%0d physical_writes=%0d clear_writes=%0d status=%h",
                 clock_phase_ns, assertions_passed, swap_commits,
                 physical_writes, clear_writes, status);
        $display("SUMMARY: PASS P08B AC-02..AC-05 state matrix phase=%0d", clock_phase_ns);
        $finish;
    end
endmodule
