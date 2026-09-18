`timescale 1ns/1ps

module tb_p08b_vga_back_to_back;
    reg clock_50 = 0;
    reg hclk = 0;
    reg hresetn = 0;
    reg [31:0] haddr = 0;
    reg hwrite = 0;
    reg [1:0] htrans = 0;
    reg [2:0] hsize = 3'b010;
    reg [31:0] hwdata = 0;
    reg hsel = 0;
    reg stall_gate = 0;
    wire [31:0] hrdata;
    wire hready;
    wire hready_in = stall_gate ? 1'b0 : hready;
    wire [1:0] hresp;
    wire [3:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs;

    reg [13:0] expected_addr [0:63];
    reg [31:0] expected_data [0:63];
    reg expected_bank [0:63];
    integer q_head;
    integer q_tail;
    integer physical_writes;
    integer rejected_writes;
    integer assertions_passed;
    integer monitor_address_accepts;
    integer monitor_okay_write_completions;
    integer monitor_error_completions;
    integer ledger_complete;
    reg [31:0] ledger_addr [0:31];
    reg [2:0] ledger_size [0:31];
    reg ledger_write [0:31];
    time ledger_accept_time [0:31];
    reg [31:0] ledger_data [0:31];
    reg ledger_data_seen [0:31];
    reg ledger_expected_bank [0:31];
    integer ledger_stalls [0:31];
    integer ledger_error_waits [0:31];
    integer ledger_commits [0:31];
    reg [13:0] ledger_commit_addr [0:31];
    reg [31:0] ledger_commit_data [0:31];
    reg ledger_commit_bank [0:31];
    time ledger_complete_time [0:31];
    integer ledger_mutate_data;
    integer ledger_mutate_bank;

    always #5 clock_50 = ~clock_50;
    always #5 hclk = ~hclk;

    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50(clock_50), .HCLK(hclk), .HRESETn(hresetn),
        .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans), .HSIZE(hsize),
        .HWDATA(hwdata), .HSEL(hsel), .HREADY_IN(hready_in),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b),
        .VGA_HS(vga_hs), .VGA_VS(vga_vs)
    );

    task automatic expect_write(input [31:0] addr, input [31:0] data);
        begin
            if (q_tail >= 64) $fatal(1, "scoreboard overflow");
            expected_addr[q_tail] = addr[15:2];
            expected_data[q_tail] = data;
            // Auxiliary stimulus queue only.  The independent transaction
            // ledger below derives the bank from the frozen reset contract.
            expected_bank[q_tail] = 1'b1;
            q_tail = q_tail + 1;
        end
    endtask

    always @(posedge hclk) begin
        if (hready_in && hsel && htrans[1]) begin
            ledger_addr[monitor_address_accepts] = haddr;
            ledger_size[monitor_address_accepts] = hsize;
            ledger_write[monitor_address_accepts] = hwrite;
            ledger_accept_time[monitor_address_accepts] = $time;
            ledger_data_seen[monitor_address_accepts] = 1'b0;
            // This TB performs no swap.  The approved reset contract fixes
            // VRAM0 as front and VRAM1 as back; no DUT bank output is used as
            // the expected value.
            ledger_expected_bank[monitor_address_accepts] = 1'b1;
            ledger_stalls[monitor_address_accepts] = 0;
            ledger_error_waits[monitor_address_accepts] = 0;
            ledger_commits[monitor_address_accepts] = 0;
            ledger_commit_addr[monitor_address_accepts] = 14'd0;
            ledger_commit_data[monitor_address_accepts] = 32'd0;
            ledger_commit_bank[monitor_address_accepts] = 1'b0;
            monitor_address_accepts = monitor_address_accepts + 1;
            $display("BUS_ACCEPT id=%0d time=%0t addr=%h write=%0b size=%0b",
                     monitor_address_accepts - 1, $time, haddr, hwrite, hsize);
        end

        if (dut.data_valid) begin
            if (ledger_complete >= monitor_address_accepts)
                $fatal(1, "data phase without accepted transaction");
            if (!ledger_data_seen[ledger_complete]) begin
                ledger_data[ledger_complete] = hwdata;
                ledger_data_seen[ledger_complete] = 1'b1;
                if (ledger_mutate_data && ledger_complete == 0)
                    ledger_data[ledger_complete] = hwdata ^ 32'h0000_0001;
                if (ledger_mutate_bank && ledger_complete == 0)
                    ledger_expected_bank[ledger_complete] = 1'b0;
                $display("TX_DATA id=%0d time=%0t data=%h", ledger_complete,
                         $time, hwdata);
            end else if (hwdata !== ledger_data[ledger_complete] &&
                         !(ledger_mutate_data && ledger_complete == 0)) begin
                $fatal(1, "data changed while owned id=%0d got=%h expected=%h",
                       ledger_complete, hwdata, ledger_data[ledger_complete]);
            end
            if (!hready_in)
                ledger_stalls[ledger_complete] =
                    ledger_stalls[ledger_complete] + 1;
            if (hresp == 2'b01 && !hready) begin
                ledger_error_waits[ledger_complete] =
                    ledger_error_waits[ledger_complete] + 1;
                if (dut.vram0_we || dut.vram1_we)
                    $fatal(1, "ERROR wait committed id=%0d", ledger_complete);
                $display("TX_ERROR_WAIT id=%0d time=%0t", ledger_complete, $time);
            end
        end

        if (dut.vram0_we || dut.vram1_we) begin
            if (ledger_complete >= monitor_address_accepts ||
                !ledger_data_seen[ledger_complete])
                $fatal(1, "orphan physical commit id=%0d", ledger_complete);
            ledger_commits[ledger_complete] = ledger_commits[ledger_complete] + 1;
            ledger_commit_addr[ledger_complete] = dut.write_addr;
            ledger_commit_data[ledger_complete] = dut.write_data;
            ledger_commit_bank[ledger_complete] = dut.vram1_we;
            if (ledger_commits[ledger_complete] != 1)
                $fatal(1, "duplicate physical commit id=%0d count=%0d",
                       ledger_complete, ledger_commits[ledger_complete]);
            if (dut.write_addr !== ledger_addr[ledger_complete][15:2] ||
                dut.write_data !== ledger_data[ledger_complete] ||
                dut.vram1_we !== ledger_expected_bank[ledger_complete] ||
                dut.vram0_we !== ~ledger_expected_bank[ledger_complete])
                $fatal(1, "independent commit mismatch id=%0d addr=%0d/%0d data=%h/%h bank=%0d/%0d",
                       ledger_complete, dut.write_addr,
                       ledger_addr[ledger_complete][15:2], dut.write_data,
                       ledger_data[ledger_complete], dut.vram1_we,
                       ledger_expected_bank[ledger_complete]);
            $display("TX_COMMIT id=%0d time=%0t addr=%0d data=%h bank=%0d",
                     ledger_complete, $time, dut.write_addr, dut.write_data,
                     dut.vram1_we);
        end

        if (dut.data_valid && hready_in && hready) begin
            if (ledger_complete >= monitor_address_accepts)
                $fatal(1, "completion without accepted transaction");
            if (hresp == 2'b00 && dut.data_write && dut.data_is_fb) begin
                monitor_okay_write_completions = monitor_okay_write_completions + 1;
                if (ledger_size[ledger_complete] !== 3'b010 ||
                    !ledger_write[ledger_complete] ||
                    ledger_addr[ledger_complete] < 32'h2000_0000 ||
                    ledger_addr[ledger_complete] > 32'h2000_95ff ||
                    ledger_addr[ledger_complete][1:0] != 2'b00 ||
                    ledger_commits[ledger_complete] != 1)
                    $fatal(1, "ledger OKAY/commit mismatch id=%0d addr=%h data=%h",
                           ledger_complete, ledger_addr[ledger_complete],
                           ledger_data[ledger_complete]);
            end else if (hresp == 2'b01) begin
                monitor_error_completions = monitor_error_completions + 1;
                if (ledger_error_waits[ledger_complete] != 1 ||
                    ledger_commits[ledger_complete] != 0)
                    $fatal(1, "ledger ERROR mismatch id=%0d waits=%0d commits=%0d",
                           ledger_complete, ledger_error_waits[ledger_complete],
                           ledger_commits[ledger_complete]);
            end else begin
                $fatal(1, "unexpected completion id=%0d resp=%02b", ledger_complete,
                       hresp);
            end
            ledger_complete_time[ledger_complete] = $time;
            $display("TX_COMPLETE id=%0d time=%0t addr=%h size=%0b write=%0b data=%h resp=%02b stalls=%0d error_waits=%0d commits=%0d commit_addr=%0d commit_data=%h commit_bank=%0d",
                     ledger_complete, $time, ledger_addr[ledger_complete],
                     ledger_size[ledger_complete],
                     ledger_write[ledger_complete], ledger_data[ledger_complete],
                     hresp, ledger_stalls[ledger_complete],
                     ledger_error_waits[ledger_complete],
                     ledger_commits[ledger_complete],
                     ledger_commit_addr[ledger_complete],
                     ledger_commit_data[ledger_complete],
                     ledger_commit_bank[ledger_complete]);
            ledger_complete = ledger_complete + 1;
        end
        if (dut.vram0_we || dut.vram1_we) begin
            physical_writes = physical_writes + 1;
            if (q_head >= q_tail)
                $fatal(1, "unexpected physical write addr=%0d data=%h",
                       dut.write_addr, dut.write_data);
            if (dut.write_addr !== expected_addr[q_head])
                $fatal(1, "write address mismatch index=%0d got=%0d expected=%0d",
                       q_head, dut.write_addr, expected_addr[q_head]);
            if (dut.write_data !== expected_data[q_head])
                $fatal(1, "write data mismatch index=%0d got=%h expected=%h",
                       q_head, dut.write_data, expected_data[q_head]);
            if (dut.vram1_we !== expected_bank[q_head] ||
                dut.vram0_we !== ~expected_bank[q_head])
                $fatal(1, "write bank mismatch index=%0d vram0=%b vram1=%b expected_bank=%0d",
                       q_head, dut.vram0_we, dut.vram1_we, expected_bank[q_head]);
            if ((dut.vram0_we && dut.front_bank_p == 1'b0) ||
                (dut.vram1_we && dut.front_bank_p == 1'b1))
                $fatal(1, "front bank write index=%0d", q_head);
            q_head = q_head + 1;
        end
        if (dut.vram0_we && dut.vram1_we)
            $fatal(1, "both physical banks written");
    end

    task automatic drive_idle(input [31:0] data);
        begin
            hsel = 0;
            htrans = 2'b00;
            hwrite = 0;
            hsize = 3'b010;
            haddr = 0;
            hwdata = data;
        end
    endtask

    task automatic wait_ready;
        integer cycles;
        begin
            cycles = 0;
            while (!dut.domain_ready && cycles < 200) begin
                @(posedge hclk);
                cycles = cycles + 1;
            end
            if (!dut.domain_ready) $fatal(1, "DOMAIN_READY timeout");
        end
    endtask

    task automatic check_queue_empty(input [511:0] label);
        begin
            @(posedge hclk); #1;
            if (q_head != q_tail)
                $fatal(1, "%0s outstanding=%0d", label, q_tail-q_head);
            assertions_passed = assertions_passed + 1;
            $display("ASSERT_PASS %0s writes=%0d", label, physical_writes);
        end
    endtask

    task automatic single_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
            haddr = addr;
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b00) $fatal(1, "address phase not accepted");
            @(negedge hclk);
            expect_write(addr, data);
            drive_idle(data);
        end
    endtask

    task automatic rejected_write(input [31:0] addr, input [2:0] size,
                                  input [31:0] data);
        integer before_count;
        begin
            before_count = physical_writes;
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = size;
            haddr = addr; hwdata = data;
            @(posedge hclk); #1;
            if (hready || hresp != 2'b01) $fatal(1, "missing ERROR wait cycle");
            if (physical_writes != before_count) $fatal(1, "WE during ERROR wait");
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b01) $fatal(1, "missing ERROR final cycle");
            if (physical_writes != before_count) $fatal(1, "WE during ERROR final");
            // The final response is visible for the following bus cycle.
            // Present IDLE in its address phase while holding this transfer's
            // data through the closing rising edge.
            @(negedge hclk);
            drive_idle(data);
            @(posedge hclk);
            rejected_writes = rejected_writes + 1;
            @(negedge hclk);
            drive_idle(0);
            @(posedge hclk); #1;
            assertions_passed = assertions_passed + 1;
            $display("ASSERT_PASS rejected_no_we addr=%h", addr);
        end
    endtask

    initial begin : test
        integer i;
        reg [31:0] addr_seq [0:3];
        reg [31:0] data_seq [0:3];

        q_head = 0;
        q_tail = 0;
        physical_writes = 0;
        rejected_writes = 0;
        assertions_passed = 0;
        monitor_address_accepts = 0;
        monitor_okay_write_completions = 0;
        monitor_error_completions = 0;
        ledger_complete = 0;
        ledger_mutate_data = 0;
        ledger_mutate_bank = 0;
        if ($test$plusargs("LEDGER_MUTATE_DATA")) ledger_mutate_data = 1;
        if ($test$plusargs("LEDGER_MUTATE_BANK")) ledger_mutate_bank = 1;
        drive_idle(0);

        repeat (4) @(posedge hclk);
        hresetn = 1;
        wait_ready();

        // Consecutive addresses with a different data word on every transfer.
        addr_seq[0] = 32'h2000_0000; data_seq[0] = 32'h1111_0001;
        addr_seq[1] = 32'h2000_0004; data_seq[1] = 32'h2222_0002;
        addr_seq[2] = 32'h2000_0008; data_seq[2] = 32'h3333_0003;
        addr_seq[3] = 32'h2000_000c; data_seq[3] = 32'h4444_0004;
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = addr_seq[0];
        for (i = 0; i < 3; i = i + 1) begin
            @(negedge hclk);
            expect_write(addr_seq[i], data_seq[i]);
            haddr = addr_seq[i+1];
            hwdata = data_seq[i];
        end
        @(negedge hclk);
        expect_write(addr_seq[3], data_seq[3]);
        drive_idle(data_seq[3]);
        check_queue_empty("consecutive_addresses");

        // Same-address consecutive writes must remain ordered and distinct.
        addr_seq[0] = 32'h2000_0040; data_seq[0] = 32'haaaa_0001;
        addr_seq[1] = 32'h2000_0040; data_seq[1] = 32'hbbbb_0002;
        addr_seq[2] = 32'h2000_0040; data_seq[2] = 32'hcccc_0003;
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = addr_seq[0];
        for (i = 0; i < 2; i = i + 1) begin
            @(negedge hclk);
            expect_write(addr_seq[i], data_seq[i]);
            haddr = addr_seq[i+1];
            hwdata = data_seq[i];
        end
        @(negedge hclk);
        expect_write(addr_seq[2], data_seq[2]);
        drive_idle(data_seq[2]);
        check_queue_empty("same_address_ordered");

        // First and final canonical framebuffer words.
        single_write(32'h2000_0000, 32'hface_0000);
        check_queue_empty("first_word");
        single_write(32'h2000_95fc, 32'hface_095f);
        check_queue_empty("last_word");

        // Upstream HREADY stall before address acceptance.
        @(negedge hclk);
        stall_gate = 1;
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2000_0080; hwdata = 32'h5555_0080;
        repeat (3) begin
            @(posedge hclk); #1;
            if (dut.data_valid || dut.vram0_we || dut.vram1_we)
                $fatal(1, "transfer advanced during HREADY_IN stall");
        end
        @(negedge hclk);
        stall_gate = 0;
        @(posedge hclk); #1;
        @(negedge hclk);
        expect_write(32'h2000_0080, 32'h5555_0080);
        drive_idle(32'h5555_0080);
        check_queue_empty("hready_stall_then_accept");

        // Accepted write followed by a rejected transfer, then another accept.
        single_write(32'h2000_0100, 32'h6000_0100);
        check_queue_empty("accept_before_reject");
        rejected_write(32'h2000_9600, 3'b010, 32'hdead_beef);
        single_write(32'h2000_0104, 32'h7000_0104);
        check_queue_empty("accept_after_reject");

        // Hold an already accepted data phase with HREADY_IN low. The
        // physical write must occur exactly once, only after release.
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2000_0120;
        @(posedge hclk); #1;
        if (!dut.data_valid || dut.data_rejected)
            $fatal(1, "data-stall address was not accepted");
        @(negedge hclk);
        expect_write(32'h2000_0120, 32'h8120_0001);
        drive_idle(32'h8120_0001);
        stall_gate = 1;
        repeat (3) begin
            @(posedge hclk); #1;
            if (q_head != q_tail - 1)
                $fatal(1, "write committed during data-phase stall");
        end
        @(negedge hclk); stall_gate = 0;
        check_queue_empty("accepted_data_phase_stall_exactly_once");

        // Fastest legal accept -> reject -> accept sequence. The recovery
        // address/control is held throughout the VGA two-cycle ERROR.
        @(negedge hclk);
        hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
        haddr = 32'h2000_0140;
        @(negedge hclk);
        expect_write(32'h2000_0140, 32'h9140_0001);
        haddr = 32'h2000_9600;
        hwdata = 32'h9140_0001;
        @(posedge hclk);
        if (!hready || hresp != 2'b00)
            $fatal(1, "accepted predecessor did not complete OKAY");
        #1;
        if (hready || hresp != 2'b01)
            $fatal(1, "pipelined reject missing ERROR wait after predecessor");
        @(negedge hclk);
        haddr = 32'h2000_0144;
        hwdata = 32'hdead_beef;
        #1;
        if (hready || hresp != 2'b01)
            $fatal(1, "pipelined reject missing ERROR wait");
        @(posedge hclk); #1;
        if (!hready || hresp != 2'b01)
            $fatal(1, "pipelined reject missing ERROR final");
        if (q_head != q_tail)
            $fatal(1, "accepted predecessor physical commit missing");
        @(posedge hclk); #1;
        if (!dut.data_valid || dut.data_rejected)
            $fatal(1, "held recovery address not accepted");
        @(negedge hclk);
        expect_write(32'h2000_0144, 32'ha144_0002);
        drive_idle(32'ha144_0002);
        check_queue_empty("pipelined_accept_reject_accept");

        if (q_head != q_tail) $fatal(1, "final outstanding transactions");
        if (monitor_address_accepts != 17 ||
            monitor_okay_write_completions != 15 ||
            monitor_error_completions != 2 || physical_writes != 15)
            $fatal(1, "independent bus monitor mismatch accepts=%0d okay=%0d error=%0d physical=%0d",
                   monitor_address_accepts, monitor_okay_write_completions,
                   monitor_error_completions, physical_writes);
        if (ledger_complete != monitor_address_accepts)
            $fatal(1, "ledger outstanding=%0d", monitor_address_accepts-ledger_complete);
        if (dut.front_bank_h !== 1'b0 || dut.front_bank_p !== 1'b0)
            $fatal(1, "unexpected ownership change front_h=%0b front_p=%0b",
                   dut.front_bank_h, dut.front_bank_p);
        assertions_passed = assertions_passed + 1;
        $display("ASSERT_PASS F02-INDEPENDENT-LEDGER accepts=17 okay=15 error=2 physical=15 outstanding=0 expected_bank=VRAM1 source=reset_contract");
        $display("OBSERVED accepted=%0d physical=%0d rejected=%0d assertions=%0d",
                 q_tail, physical_writes, rejected_writes, assertions_passed);
        $display("SUMMARY: PASS P08B AC-01 back-to-back accepted writes");
        $finish;
    end
endmodule
