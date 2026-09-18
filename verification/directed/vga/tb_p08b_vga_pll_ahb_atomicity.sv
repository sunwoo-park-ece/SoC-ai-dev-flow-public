`timescale 1ns/1ps

module tb_p08b_vga_pll_ahb_atomicity;
    reg         clock_50 = 1'b0;
    reg         hclk = 1'b0;
    reg         hresetn = 1'b0;
    reg  [31:0] haddr = 32'h0;
    reg         hwrite = 1'b0;
    reg  [1:0]  htrans = 2'b00;
    reg  [2:0]  hsize = 3'b010;
    reg  [31:0] hwdata = 32'h0;
    reg         hsel = 1'b0;
    reg         hready_in = 1'b1;
    wire [31:0] hrdata;
    wire        hready;
    wire [1:0]  hresp;
    wire [3:0]  vga_r;
    wire [3:0]  vga_g;
    wire [3:0]  vga_b;
    wire        vga_hs;
    wire        vga_vs;

    integer cycle_count;
    integer physical_commits;
    integer final_okay_completions;
    integer transaction_id;

    localparam [31:0] TEST_ADDR = 32'h2000_0040;
    localparam [31:0] TEST_DATA = 32'hf01a_7001;

    always #5 clock_50 = ~clock_50;
    always #5 hclk = ~hclk;

    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50(clock_50),
        .HCLK(hclk),
        .HRESETn(hresetn),
        .HADDR(haddr),
        .HWRITE(hwrite),
        .HTRANS(htrans),
        .HSIZE(hsize),
        .HWDATA(hwdata),
        .HSEL(hsel),
        .HREADY_IN(hready_in),
        .HRDATA(hrdata),
        .HREADY(hready),
        .HRESP(hresp),
        .VGA_R(vga_r),
        .VGA_G(vga_g),
        .VGA_B(vga_b),
        .VGA_HS(vga_hs),
        .VGA_VS(vga_vs)
    );

    task automatic drive_idle(input [31:0] data);
        begin
            haddr = 32'h0;
            hwrite = 1'b0;
            htrans = 2'b00;
            hsize = 3'b010;
            hwdata = data;
            hsel = 1'b0;
        end
    endtask

    task automatic wait_domain_ready;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!dut.domain_ready && wait_cycles < 200) begin
                @(posedge hclk);
                wait_cycles = wait_cycles + 1;
            end
            if (!dut.domain_ready) begin
                $display("ASSERT_FAIL id=F01-PRECONDITION reason=DOMAIN_READY_TIMEOUT cycles=%0d",
                         wait_cycles);
                $fatal(1, "F01 precondition timeout");
            end
            $display("ASSERT_PASS id=F01-PRECONDITION domain_ready=1 cycles=%0d",
                     wait_cycles);
        end
    endtask

    always @(posedge hclk) begin
        cycle_count = cycle_count + 1;
        if (dut.vram0_we || dut.vram1_we)
            physical_commits = physical_commits + 1;
        $display("TRACE tx=%0d cycle=%0d time=%0t HADDR=%08h HTRANS=%02b HSIZE=%03b HWRITE=%0b HSEL=%0b HREADY_IN=%0b HREADY=%0b HRESP=%02b data_valid=%0b data_rejected=%0b pll_locked=%0b domain_ready=%0b physical_we=%0b vram0_we=%0b vram1_we=%0b write_addr=%0d write_data=%08h",
                 transaction_id, cycle_count, $time, haddr, htrans, hsize,
                 hwrite, hsel, hready_in, hready, hresp, dut.data_valid,
                 dut.data_rejected, dut.vga_pll_locked, dut.domain_ready,
                 dut.physical_write, dut.vram0_we, dut.vram1_we,
                 dut.write_addr, dut.write_data);
    end

    initial begin : timeout_guard
        #5000;
        $display("ASSERT_FAIL id=F01-TIMEOUT time=%0t", $time);
        $fatal(1, "F01 explicit timeout");
    end

    initial begin : f01_address_accept_then_lock_loss
        integer commits_before;

        cycle_count = 0;
        physical_commits = 0;
        final_okay_completions = 0;
        transaction_id = 0;
        drive_idle(32'h0);

        repeat (4) @(posedge hclk);
        hresetn = 1'b1;
        wait_domain_ready();

        transaction_id = 1;
        commits_before = physical_commits;

        // Present a canonical framebuffer write address. The rising edge
        // accepts it while both the synchronized domain and raw PLL lock are
        // ready. The behavioral PLL hook is then invoked after that edge but
        // before the write's data-phase commit edge.
        @(negedge hclk);
        haddr = TEST_ADDR;
        hwrite = 1'b1;
        htrans = 2'b10;
        hsize = 3'b010;
        hsel = 1'b1;
        hwdata = 32'h0;

        @(posedge hclk);
        #1;
        if (!hready || hresp !== 2'b00 || !dut.data_valid ||
            dut.data_rejected) begin
            $display("ASSERT_FAIL id=F01-ADDRESS-ACCEPT HREADY=%0b HRESP=%02b data_valid=%0b rejected=%0b",
                     hready, hresp, dut.data_valid, dut.data_rejected);
            $fatal(1, "canonical address was not accepted");
        end
        $display("ASSERT_PASS id=F01-ADDRESS-ACCEPT tx=1 time=%0t domain_ready=%0b pll_locked=%0b",
                 $time, dut.domain_ready, dut.vga_pll_locked);

        dut.U_PLL.inject_lock_loss();
        #1;
        $display("INJECT tx=1 event=PLL_LOCK_LOSS time=%0t phase=AFTER_ADDRESS_ACCEPT_BEFORE_DATA_COMMIT pll_locked=%0b domain_ready=%0b",
                 $time, dut.vga_pll_locked, dut.domain_ready);

        @(negedge hclk);
        drive_idle(TEST_DATA);

        // Option A: loss before physical commit converts this outstanding
        // write to the first cycle of the VGA-owned two-cycle ERROR.
        #1;
        if (hready || hresp !== 2'b01 ||
            (physical_commits - commits_before) != 0) begin
            $display("ASSERT_FAIL id=F01-ERROR-WAIT HREADY=%0b HRESP=%02b commits=%0d",
                     hready, hresp, physical_commits - commits_before);
            $fatal(1, "missing first ERROR cycle or unexpected commit");
        end
        $display("ASSERT_PASS id=F01-ERROR-WAIT tx=1 HREADY=0 HRESP=ERROR commits=0");

        // At the next edge the response advances to final ERROR. Physical WE
        // must remain zero; this transfer must never be counted as OKAY.
        @(posedge hclk);
        if (hready && hresp === 2'b00)
            final_okay_completions = final_okay_completions + 1;
        #1;
        $display("OBSERVED tx=1 final_hready=%0b final_hresp=%02b commits_delta=%0d total_commits=%0d pll_locked=%0b domain_ready=%0b",
                 hready, hresp, physical_commits - commits_before,
                 physical_commits, dut.vga_pll_locked, dut.domain_ready);

        if (!hready || hresp !== 2'b01) begin
            $display("ASSERT_FAIL id=F01-ERROR-FINAL HREADY=%0b HRESP=%02b",
                     hready, hresp);
            $fatal(1, "missing final ERROR cycle");
        end

        if (final_okay_completions != 0 ||
            (physical_commits - commits_before) != 0) begin
            $display("ASSERT_FAIL id=F01-ERROR-IMPLIES-ZERO-COMMIT tx=1 final_okay=%0d physical_commits=%0d expected_commits=0",
                     final_okay_completions,
                     physical_commits - commits_before);
            $fatal(1, "F01 Option A invariant violated");
        end

        $display("ASSERT_PASS id=F01-ERROR-IMPLIES-ZERO-COMMIT tx=1 final_okay=0 commits=0");
        $display("SUMMARY: PASS P08B F01 Option A first boundary");
        $finish;
    end
endmodule
