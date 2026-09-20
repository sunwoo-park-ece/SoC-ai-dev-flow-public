`timescale 1ns/1ps
// Contract-driven P09B focused check. Stimulus bytes and expected APB values
// are constants from spec/12_gsensor.md, never copied from DUT bank state.
module tb_gsensor_snapshot;
    localparam [31:0] BASE = 32'h4003_0000;
    reg clk = 0, rst_n = 0;
    reg [2:1] irq = 2'b00;
    reg miso = 0;
    reg [31:0] paddr = 0, pwdata = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    wire [31:0] prdata;
    wire pready, pslverr, cs_n, sclk, mosi;
    wire [15:0] debug_x, debug_y;
    integer edges = 0, transfers = 0, reads = 0, arm_edge = -1;
    integer checks = 0;
    reg [15:0] init_expected [0:11];
    reg [55:0] tx_seen;
    reg [47:0] rx_script;
    integer bit_count, bit_idx;
    reg [55:0] expected_tx;

    always #10 clk = ~clk;
    always @(posedge clk) edges = edges + 1;
    APB_GSENSOR_MB dut (
        .PCLK(clk), .PRESETn(rst_n), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(prdata),
        .PREADY(pready), .PSLVERR(pslverr), .GSENSOR_CS_N(cs_n),
        .GSENSOR_INT(irq), .GSENSOR_SCLK(sclk), .GSENSOR_SDI(mosi),
        .GSENSOR_SDO(miso), .debug_acc_x(debug_x), .debug_acc_y(debug_y)
    );

    task automatic fail(input [255:0] name);
        begin $display("FAIL %0s edge=%0d time=%0t", name, edges, $time); $fatal(1); end
    endtask
    task automatic eq32(input [31:0] got, input [31:0] want, input [255:0] name);
        begin
            if (got !== want) begin
                $display("FAIL %0s got=%08h want=%08h", name, got, want);
                $fatal(1);
            end
            checks = checks + 1;
        end
    endtask

    // Independent digital sensor peer. Complete frames and sampled MOSI bits
    // are checked on external pins; no internal init table or read data used.
    initial begin : sensor_peer
        forever begin
            @(negedge cs_n);
            if (!rst_n) fail("CS active during reset");
            if (sclk !== 1'b1) fail("Mode-3 idle SCLK");
            if (transfers < 12) begin
                bit_count = 16;
                expected_tx = {40'h0, init_expected[transfers]};
            end else begin
                bit_count = 56;
                expected_tx = {8'hf2, 48'h0};
                if (reads == 0) rx_script = 48'h3412_7856_bc9a;
                else if (reads == 1) rx_script = 48'hbc9a_f0de_3412;
                else if (reads == 2) rx_script = 48'h7856_3412_efcd;
                else rx_script = 48'h00ff_00aa_0055;
                if (reads == 0 && arm_edge < 0) fail("read before init CS high");
                reads = reads + 1;
            end
            tx_seen = 0;
            for (bit_idx = 0; bit_idx < bit_count; bit_idx = bit_idx + 1) begin
                @(negedge sclk);
                #1;
                if (cs_n !== 0) fail("CS rose inside frame");
                if (mosi !== expected_tx[bit_count-1-bit_idx]) fail("MOSI bit");
                if (bit_count == 56 && bit_idx >= 8)
                    miso = rx_script[55-bit_idx];
                else miso = 0;
                @(posedge sclk);
                #1;
                tx_seen = {tx_seen[54:0], mosi};
            end
            if (tx_seen !== expected_tx) fail("complete SPI frame");
            @(posedge cs_n);
            if (sclk !== 1'b1) fail("CS high while SCLK low");
            transfers = transfers + 1;
            if (transfers == 12) arm_edge = edges;
            $display("CHECK SPI frame=%0d bits=%0d tx=%014h edge=%0d", transfers, bit_count, tx_seen, edges);
            checks = checks + 1;
        end
    end

    task automatic apb_read(input [31:0] addr, input [31:0] want);
        begin
            @(negedge clk);
            paddr = addr; pwrite = 0; psel = 1; penable = 0;
            @(negedge clk); penable = 1;
            #1;
            if (pready !== 1 || pslverr !== 0) fail("legal APB read response");
            eq32(prdata, want, "APB read data");
            @(posedge clk); #1;
            psel = 0; penable = 0;
        end
    endtask
    task automatic apb_write(input [31:0] addr, input [31:0] data, input err);
        begin
            @(negedge clk);
            paddr = addr; pwdata = data; pwrite = 1; psel = 1; penable = 0;
            @(negedge clk); penable = 1;
            #1;
            if (pready !== 1 || pslverr !== err) fail("APB write response");
            @(posedge clk); #1;
            psel = 0; penable = 0; pwrite = 0;
            checks = checks + 1;
        end
    endtask

    initial begin : main
        init_expected[0]=16'h2420; init_expected[1]=16'h2503;
        init_expected[2]=16'h2601; init_expected[3]=16'h277f;
        init_expected[4]=16'h2809; init_expected[5]=16'h2946;
        init_expected[6]=16'h2c09; init_expected[7]=16'h2f00;
        init_expected[8]=16'h2e80; init_expected[9]=16'h3100;
        init_expected[10]=16'h2007; init_expected[11]=16'h2d08;
        @(posedge clk); #1;
        if (cs_n !== 1 || sclk !== 1) fail("reset SPI pins");
        @(negedge clk); rst_n = 1;
        irq[1] = 1; // Already HIGH when scheduler arms: exactly one IRQ.
        apb_write(BASE+16, 32'h1, 0); // No complete LIVE yet: legal no-op.
        apb_read(BASE+8, 32'h0);
        wait (arm_edge >= 0);
        if (transfers !== 12 || reads !== 0) fail("init count or premature read");
        wait (reads == 1);
        // 55 external rising samples, then the final falling SCLK. E0 is
        // 13 PCLKs after that fall. Put SETUP on E0 and ACCESS on E1.
        repeat (55) @(posedge sclk);
        @(negedge sclk);
        repeat (12) @(posedge clk);
        @(negedge clk);
        paddr = BASE+8; pwrite = 0; psel = 1; penable = 0;
        @(posedge sclk); // E0: source axes/ready registered, LIVE still old.
        @(negedge clk); penable = 1;
        #1;
        if (pready !== 1 || pslverr !== 0) fail("concurrent STATUS response");
        eq32(prdata, 32'h0, "STATUS pre-E1 publication");
        @(posedge clk); #1; // E1: the accepted read saw pre-edge zero.
        psel = 0; penable = 0;
        wait (cs_n == 1);
        repeat (3) @(posedge clk);
        apb_read(BASE+8, 32'h1);
        apb_read(BASE+0, 32'h0);
        apb_read(BASE+4, 32'h0);
        apb_read(BASE+12, 32'h0);
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+8, 32'h2);
        apb_read(BASE+0, 32'h1234_5678);
        apb_read(BASE+4, 32'h0000_9abc);
        apb_read(BASE+12, 32'h1);
        apb_write(BASE+16, 32'h1, 0); // Occupied: no replacement.
        apb_write(BASE+16, 32'h3, 1); // Malformed: no RELEASE.
        apb_read(BASE+8, 32'h2);
        if (reads !== 1) fail("stuck HIGH generated duplicate read");

        // Rearm only after a synchronized LOW, then request a second tuple.
        @(negedge clk); irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 2);
        wait (cs_n == 1);
        repeat (3) @(posedge clk);
        apb_read(BASE+8, 32'h3);
        apb_read(BASE+0, 32'h1234_5678); // HOLD remains first generation.
        apb_read(BASE+4, 32'h0000_9abc);
        apb_read(BASE+12, 32'h1);
        apb_write(BASE+16, 32'h2, 0);
        apb_read(BASE+8, 32'h1);
        apb_read(BASE+0, 32'h0);
        apb_read(BASE+4, 32'h0);
        apb_read(BASE+12, 32'h0);
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+0, 32'h9abc_def0);
        apb_read(BASE+4, 32'h0000_1234);
        apb_read(BASE+12, 32'h2);
        apb_write(BASE+16, 32'h2, 0); // Free HOLD, LIVE has no pending sample.
        @(negedge clk); irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 3);
        wait (cs_n == 1);
        repeat (3) @(posedge clk);
        apb_read(BASE+8, 32'h1); // Third tuple pending, HOLD empty.
        @(negedge clk); irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 4);
        repeat (55) @(posedge sclk);
        @(negedge sclk);
        repeat (12) @(posedge clk);
        @(negedge clk);
        paddr = BASE+16; pwdata = 32'h1; pwrite = 1; psel = 1; penable = 0;
        @(posedge sclk); // E0 fourth tuple, SETUP captures exact command.
        @(negedge clk); penable = 1;
        #1;
        if (pslverr !== 0 || pready !== 1) fail("event+CAPTURE response");
        @(posedge clk); #1; // E1: old third -> HOLD; fourth -> LIVE.
        psel = 0; penable = 0; pwrite = 0;
        wait (cs_n == 1);
        apb_read(BASE+8, 32'h3);
        apb_read(BASE+0, 32'h5678_1234);
        apb_read(BASE+4, 32'h0000_cdef);
        apb_read(BASE+12, 32'h3);
        apb_write(BASE+16, 32'h2, 0);
        apb_read(BASE+8, 32'h1); // RELEASE did not consume fourth LIVE.
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+0, 32'hff00_aa00);
        apb_read(BASE+4, 32'h0000_5500);
        apb_read(BASE+12, 32'h4);
        apb_write(BASE+16, 32'h2, 0);
        @(negedge clk); irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 5); // Sensor peer repeats the fourth physical bytes.
        wait (cs_n == 1);
        repeat (3) @(posedge clk);
        apb_read(BASE+8, 32'h1);
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+0, 32'hff00_aa00);
        apb_read(BASE+4, 32'h0000_5500);
        apb_read(BASE+12, 32'h5); // Digital completion, not XYZ inequality.
        @(negedge clk); irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 6);
        repeat (55) @(posedge sclk);
        @(negedge sclk);
        repeat (12) @(posedge clk);
        @(negedge clk);
        paddr = BASE+16; pwdata = 32'h2; pwrite = 1; psel = 1; penable = 0;
        @(posedge sclk); // E0 sixth tuple, RELEASE still SETUP.
        @(negedge clk); penable = 1;
        #1;
        if (pslverr !== 0 || pready !== 1) fail("event+RELEASE response");
        @(posedge clk); #1; // E1: RELEASE clears HOLD, event publishes LIVE.
        psel = 0; penable = 0; pwrite = 0;
        wait (cs_n == 1);
        apb_read(BASE+8, 32'h1);
        apb_read(BASE+0, 32'h0);
        apb_read(BASE+4, 32'h0);
        apb_read(BASE+12, 32'h0);
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+12, 32'h6);
        apb_write(BASE+16, 32'h2, 0);
        // Reachability acceleration only: seed the internal counter, never
        // the expected HOLD or APB readback. The next real burst must wrap.
        @(negedge clk); dut.live_seq = 32'hffff_ffff;
        irq[1] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); irq[1] = 1;
        wait (reads == 7);
        wait (cs_n == 1);
        repeat (3) @(posedge clk);
        apb_read(BASE+8, 32'h1);
        apb_write(BASE+16, 32'h1, 0);
        apb_read(BASE+8, 32'h2);
        apb_read(BASE+0, 32'hff00_aa00);
        apb_read(BASE+4, 32'h0000_5500);
        apb_read(BASE+12, 32'h0); // Wrapped zero is valid, not a sentinel.
        // Reset during HOLD ownership invalidates both generations and
        // restarts the entire 12-frame initialization without a local delay.
        @(negedge clk); rst_n = 0; irq[1] = 0;
        transfers = 0; reads = 0; arm_edge = -1;
        #1;
        if (cs_n !== 1 || sclk !== 1 || debug_x !== 0 || debug_y !== 0)
            fail("asynchronous reset pins/data");
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        apb_read(BASE+8, 32'h0);
        apb_read(BASE+0, 32'h0);
        apb_read(BASE+4, 32'h0);
        apb_read(BASE+12, 32'h0);
        wait (arm_edge >= 0);
        if (transfers !== 12 || reads !== 0) fail("reset did not restart exact init");
        $display("SUMMARY: PASS snapshot checks=%0d init=12 reads=%0d", checks, reads);
        $finish;
    end

    initial begin
        #40_000_000;
        fail("global timeout");
    end
endmodule

// Reset/abort-only companion. It intentionally uses a separate DUT so the
// established snapshot sequence above remains its own evidence lane.
module tb_gsensor_reset_abort;
    localparam [31:0] BASE = 32'h4003_0000;
    reg clk = 0, rst_n = 0, miso = 0;
    reg [2:1] irq = 0;
    reg [31:0] paddr = 0, pwdata = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    wire [31:0] prdata;
    wire pready, pslverr, cs_n, sclk, mosi;
    wire [15:0] debug_x, debug_y;
    integer init_frames = 0, read_frames = 0, epoch_inits = 0, epoch_reads = 0;
    integer checks = 0, bit_index;
    reg [15:0] init_expected [0:11];
    reg [55:0] expected_tx, seen_tx;
    reg [47:0] sample_bytes;

    always #10 clk = ~clk;
    APB_GSENSOR_MB dut (
        .PCLK(clk), .PRESETn(rst_n), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(prdata),
        .PREADY(pready), .PSLVERR(pslverr), .GSENSOR_CS_N(cs_n),
        .GSENSOR_INT(irq), .GSENSOR_SCLK(sclk), .GSENSOR_SDI(mosi),
        .GSENSOR_SDO(miso), .debug_acc_x(debug_x), .debug_acc_y(debug_y)
    );

    task automatic fail(input [255:0] why);
        begin $display("FAIL reset_abort %0s time=%0t", why, $time); $fatal(1); end
    endtask
    task automatic check_reset_state(input [255:0] phase);
        begin
            if (cs_n !== 1 || sclk !== 1 || mosi !== 0 ||
                dut.live_x !== 0 || dut.live_y !== 0 || dut.live_z !== 0 ||
                dut.live_seq !== 0 || dut.live_valid !== 0 ||
                dut.hold_x !== 0 || dut.hold_y !== 0 || dut.hold_z !== 0 ||
                dut.hold_seq !== 0 || dut.hold_valid !== 0 ||
                dut.u_spi_ee_config.gsensor_ready !== 0 ||
                dut.u_spi_ee_config.pending_req !== 0 ||
                dut.u_spi_ee_config.scheduler_armed !== 0)
                fail(phase);
            checks = checks + 1;
        end
    endtask
    task automatic reset_then_rearm(input [255:0] phase);
        begin
            #3 rst_n = 0;
            #1 check_reset_state(phase);
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1;
            wait (epoch_inits == 12);
            if (epoch_reads != 0 || cs_n !== 1) fail("reset restart has stale read");
            checks = checks + 1;
        end
    endtask
    task automatic make_live;
        integer target_reads;
        begin
            target_reads = read_frames + 1;
            @(negedge clk); irq[1] = 1;
            wait (read_frames == target_reads);
            wait (cs_n == 1);
            repeat (3) @(posedge clk);
            if (dut.live_valid !== 1 || dut.live_seq !== 1 || dut.hold_valid !== 0)
                fail("fresh completed burst did not make LIVE");
            @(negedge clk); irq[1] = 0;
            repeat (4) @(posedge clk);
            checks = checks + 1;
        end
    endtask
    task automatic begin_capture_setup;
        begin
            @(negedge clk);
            paddr = BASE + 16; pwdata = 1; pwrite = 1; psel = 1; penable = 0;
        end
    endtask
    task automatic clear_apb;
        begin paddr = 0; pwdata = 0; pwrite = 0; psel = 0; penable = 0; end
    endtask

    // A reset-aware external SPI peer. Its expected init words are independent
    // constants from the approved contract; read bytes make LIVE 1234/5678/9ABC.
    initial begin : peer
        forever begin : frame
            @(negedge cs_n);
            if (!rst_n) disable frame;
            if (epoch_inits < 12) expected_tx = {40'h0, init_expected[epoch_inits]};
            else begin expected_tx = {8'hf2, 48'h0}; sample_bytes = 48'h3412_7856_bc9a; end
            seen_tx = 0;
            for (bit_index = 0; bit_index < ((epoch_inits < 12) ? 16 : 56); bit_index = bit_index + 1) begin
                @(negedge sclk or negedge rst_n);
                if (!rst_n) disable frame;
                if (cs_n !== 0 || mosi !== expected_tx[((epoch_inits < 12) ? 15 : 55)-bit_index]) fail("SPI MOSI/CS");
                if (epoch_inits >= 12 && bit_index >= 8) miso = sample_bytes[55-bit_index]; else miso = 0;
                @(posedge sclk or negedge rst_n);
                if (!rst_n) disable frame;
                seen_tx = {seen_tx[54:0], mosi};
            end
            @(posedge cs_n or negedge rst_n);
            if (!rst_n) disable frame;
            if (sclk !== 1 || seen_tx !== expected_tx) fail("SPI frame completion");
            if (epoch_inits < 12) begin epoch_inits = epoch_inits + 1; init_frames = init_frames + 1; end
            else begin epoch_reads = epoch_reads + 1; read_frames = read_frames + 1; end
        end
    end
    always @(negedge rst_n) begin epoch_inits = 0; epoch_reads = 0; end

    initial begin : main
        init_expected[0]=16'h2420; init_expected[1]=16'h2503; init_expected[2]=16'h2601;
        init_expected[3]=16'h277f; init_expected[4]=16'h2809; init_expected[5]=16'h2946;
        init_expected[6]=16'h2c09; init_expected[7]=16'h2f00; init_expected[8]=16'h2e80;
        init_expected[9]=16'h3100; init_expected[10]=16'h2007; init_expected[11]=16'h2d08;
        @(negedge clk); rst_n = 1;
        wait (epoch_inits == 12);
        if (epoch_reads != 0) fail("initial arm read");

        // SETUP is not accepted: reset asserts before the following ACCESS edge.
        make_live;
        begin_capture_setup;
        #3 rst_n = 0;
        #1 check_reset_state("APB SETUP abort did not clear state");
        repeat (3) @(posedge clk);
        @(negedge clk); clear_apb(); rst_n = 1;
        wait (epoch_inits == 12);
        if (epoch_reads != 0) fail("SETUP abort left command/read");
        checks = checks + 1;

        // ACCESS is presented but reset wins before its completing PCLK edge.
        make_live;
        begin_capture_setup;
        @(negedge clk); penable = 1;
        #3 rst_n = 0;
        #1 check_reset_state("APB ACCESS abort did not clear state");
        repeat (3) @(posedge clk);
        @(negedge clk); clear_apb(); rst_n = 1;
        wait (epoch_inits == 12);
        if (epoch_reads != 0) fail("ACCESS abort left command/read");
        checks = checks + 1;

        // Here ACCESS completes first (HOLD becomes occupied), then reset
        // dominates that accepted ownership at the next asynchronous boundary.
        make_live;
        begin_capture_setup;
        @(negedge clk); penable = 1;
        @(posedge clk); #1;
        if (dut.hold_valid !== 1 || dut.live_valid !== 0 || dut.hold_seq !== 1)
            fail("CAPTURE acceptance boundary was not observed");
        #3 rst_n = 0;
        #1 check_reset_state("accepted CAPTURE reset did not cancel ownership");
        // The aborted ACCESS must be inactive throughout reset; only then may
        // reset release permit a fresh initialization sequence.
        clear_apb();
        if (psel !== 0 || penable !== 0 || pwrite !== 0) fail("APB active in reset");
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        wait (epoch_inits == 12);
        if (epoch_reads != 0 || cs_n !== 1) fail("CAPTURE reset restart stale command/read");
        checks = checks + 1;

        // E0: controller has registered the last SPI sample, but wrapper has
        // not yet consumed ready. Reset must suppress the later E1 publication.
        @(negedge clk); irq[1] = 1;
        @(negedge cs_n);
        repeat (55) @(posedge sclk);
        @(negedge sclk); repeat (12) @(posedge clk);
        @(posedge sclk); #1;
        if (dut.u_spi_ee_config.gsensor_ready !== 1 || dut.live_valid !== 0)
            fail("E0 ordering not reached");
        reset_then_rearm("E0 reset leaked old publication");
        irq[1] = 0;

        // E1: wrapper publishes one LIVE generation first; reset immediately
        // afterward must erase it and prevent any stale later completion.
        @(negedge clk); irq[1] = 1;
        @(negedge cs_n);
        repeat (55) @(posedge sclk);
        @(negedge sclk); repeat (12) @(posedge clk);
        @(posedge sclk);
        @(posedge clk); #1;
        if (dut.live_valid !== 1 || dut.live_seq !== 1) fail("E1 publication not reached");
        reset_then_rearm("E1 reset leaked LIVE generation");
        irq[1] = 0;
        $display("SUMMARY: PASS reset_abort checks=%0d init_frames=%0d", checks, init_frames);
        $finish;
    end
    initial begin #10_000_000; fail("global timeout"); end
endmodule
