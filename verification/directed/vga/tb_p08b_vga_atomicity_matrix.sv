`timescale 1ns/1ps

module tb_p08b_vga_atomicity_matrix;
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
    reg hready_in = 1;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire [3:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs;

    integer cycle_count;
    integer physical_commits;
    integer assertions_passed;
    integer transaction_id;

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
        .HWDATA(hwdata), .HSEL(hsel), .HREADY_IN(hready_in),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b),
        .VGA_HS(vga_hs), .VGA_VS(vga_vs)
    );

    always @(posedge hclk) begin
        cycle_count = cycle_count + 1;
        if (dut.vram0_we || dut.vram1_we)
            physical_commits = physical_commits + 1;
        if (dut.vram0_we && dut.vram1_we)
            $fatal(1, "both banks written");
        $display("TRACE tx=%0d cycle=%0d HADDR=%08h HTRANS=%02b HWRITE=%0b HREADY_IN=%0b HREADY=%0b HRESP=%02b valid=%0b rejected=%0b blocked=%0b lock=%0b ready=%0b physical_we=%0b addr=%0d data=%08h",
                 transaction_id, cycle_count, haddr, htrans, hwrite,
                 hready_in, hready, hresp, dut.data_valid,
                 dut.effective_data_rejected, dut.data_commit_blocked,
                 dut.vga_pll_locked, dut.domain_ready, dut.physical_write,
                 dut.write_addr, dut.write_data);
    end

    task automatic pass(input [511:0] label);
        begin
            assertions_passed = assertions_passed + 1;
            $display("ASSERT_PASS tx=%0d %0s", transaction_id, label);
        end
    endtask

    task automatic drive_idle(input [31:0] data);
        begin
            haddr = 0; hwrite = 0; htrans = 0; hsize = 3'b010;
            hwdata = data; hsel = 0;
        end
    endtask

    task automatic wait_domain_ready;
        integer n;
        begin
            n = 0;
            while (!dut.domain_ready && n < 300) begin
                @(posedge hclk); n = n + 1;
            end
            if (!dut.domain_ready) $fatal(1, "domain ready timeout");
        end
    endtask

    task automatic reset_and_ready;
        begin
            @(negedge hclk); hresetn = 0; hready_in = 1; drive_idle(0);
            repeat (5) @(posedge hclk);
            @(negedge hclk); hresetn = 1;
            wait_domain_ready();
        end
    endtask

    task automatic present_address(input [31:0] addr);
        begin
            @(negedge hclk);
            haddr = addr; hwrite = 1; htrans = 2'b10;
            hsize = 3'b010; hsel = 1; hwdata = 0;
            @(posedge hclk); #1;
            if (!dut.data_valid) $fatal(1, "address was not captured");
        end
    endtask

    task automatic expect_error_zero_commit(input [31:0] data,
                                             input integer before_count,
                                             input [255:0] label);
        begin
            @(negedge hclk); drive_idle(data); hready_in = 1;
            #1;
            if (hready || hresp !== 2'b01)
                $fatal(1, "%0s missing ERROR wait", label);
            if (physical_commits != before_count)
                $fatal(1, "%0s write during ERROR wait", label);
            @(posedge hclk); #1;
            if (!hready || hresp !== 2'b01)
                $fatal(1, "%0s missing ERROR final", label);
            if (physical_commits != before_count)
                $fatal(1, "%0s write during ERROR final", label);
            pass(label);
            @(negedge hclk); drive_idle(0);
            @(posedge hclk); #1;
        end
    endtask

    task automatic normal_write(input [31:0] addr, input [31:0] data,
                                input [255:0] label);
        integer before_count;
        begin
            before_count = physical_commits;
            present_address(addr);
            if (dut.data_rejected) $fatal(1, "%0s address rejected", label);
            @(negedge hclk); drive_idle(data);
            @(posedge hclk); #1;
            if (!hready || hresp !== 2'b00)
                $fatal(1, "%0s did not finish OKAY", label);
            if (physical_commits - before_count != 1)
                $fatal(1, "%0s commit count=%0d", label,
                       physical_commits - before_count);
            pass(label);
        end
    endtask

    initial begin : timeout_guard
        #20000;
        $fatal(1, "atomicity matrix timeout");
    end

    initial begin : test
        integer before_count;

        cycle_count = 0; physical_commits = 0; assertions_passed = 0;
        transaction_id = 0; drive_idle(0);
        $display("CONFIG CLOCK_PHASE_NS=%0d", clock_phase_ns);

        // Address accepted, then raw lock loss before the data commit edge.
        reset_and_ready(); transaction_id = 1;
        before_count = physical_commits;
        present_address(32'h2000_0040);
        if (dut.data_rejected) $fatal(1, "tx1 address rejected");
        dut.U_PLL.inject_lock_loss(); #1;
        expect_error_zero_commit(32'h1010_0001, before_count,
                                 "loss_after_address_error_zero_we");

        // Hold the accepted data phase through HREADY_IN=0, then lose lock.
        reset_and_ready(); transaction_id = 2;
        before_count = physical_commits;
        present_address(32'h2000_0044);
        @(negedge hclk); drive_idle(32'h2020_0002); hready_in = 0;
        repeat (2) begin
            @(posedge hclk); #1;
            if (physical_commits != before_count)
                $fatal(1, "tx2 committed during HREADY_IN stall");
        end
        dut.U_PLL.inject_lock_loss(); #1;
        if (hready || hresp !== 2'b01)
            $fatal(1, "tx2 missing ERROR after stalled lock loss");
        hready_in = 1;
        @(posedge hclk); #1;
        if (!hready || hresp !== 2'b01 || physical_commits != before_count)
            $fatal(1, "tx2 final ERROR/zero-WE failure");
        pass("stall_loss_error_zero_we");

        // A lock loss after a completed physical write is not retroactive.
        reset_and_ready(); transaction_id = 3;
        normal_write(32'h2000_0048, 32'h3030_0003,
                     "commit_before_loss_exactly_once");
        before_count = physical_commits;
        dut.U_PLL.inject_lock_loss(); #1;
        repeat (3) @(posedge hclk);
        #1;
        if (physical_commits != before_count || hresp !== 2'b00)
            $fatal(1, "tx3 retroactive error or duplicate commit");
        pass("post_commit_loss_not_retroactive");

        // Recover ownership/readiness and accept a new write exactly once.
        wait_domain_ready(); transaction_id = 4;
        normal_write(32'h2000_004c, 32'h4040_0004,
                     "recovery_write_exactly_once");

        // Existing invalid-address ERROR remains two-cycle with no WE.
        transaction_id = 5; before_count = physical_commits;
        present_address(32'h2000_9600);
        #1;
        if (hready || hresp !== 2'b01)
            $fatal(1, "tx5 missing invalid ERROR wait");
        @(posedge hclk); #1;
        if (!hready || hresp !== 2'b01 || physical_commits != before_count)
            $fatal(1, "tx5 invalid ERROR final/WE failure");
        pass("invalid_two_cycle_error_zero_we");

        $display("OBSERVED phase=%0d assertions=%0d physical_commits=%0d transactions=5",
                 clock_phase_ns, assertions_passed, physical_commits);
        $display("SUMMARY: PASS P08B F01 ATOMICITY MATRIX");
        $finish;
    end
endmodule
