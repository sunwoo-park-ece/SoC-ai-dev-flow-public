`timescale 1ns/1ps

// =============================================================================
// C2 SoC Directed Integration Testbench: tb_soc_adc_v2_integration
//
// Verification Authority:
//   - Issue #6 [P11C-C2 TASK] Section 15.D
//   - spec/15_adc_joystick.md, spec/05_apb_subsystem.md, spec/06_reset_clock.md
//
// Verifies full SoC C2 cutover path:
//   1. Initial reset & quiescent state: zero commands, STATUS=0.
//   2. APB ENABLE write via AHB -> mailbox CDC -> acquisition engine -> Qsys.
//   3. Qsys CH1/CH2 conversion and response -> frame mailbox -> LIVE bank.
//   4. APB CAPTURE write -> atomic copy to HOLD bank -> AHB readback of real samples.
//   5. APB disable -> engine quiesce -> LIVE invalidation -> HOLD preservation.
//   6. APB re-enable -> scan restart -> new frame capture.
//   7. Error event toggle CDC -> APB sticky ERROR_STATUS readback -> CLEAR_ERROR.
// =============================================================================

module tb_soc_adc_v2_integration;
    reg clk = 0;
    reg [1:0] KEY = 2'b10;
    reg [9:0] SW = 0;
    reg [2:1] G_SENSOR_INT = 0;
    reg G_SENSOR_SDO = 0, lora_rx = 1, lora_aux = 0, uart_rx = 1;

    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire G_SENSOR_CS_N, G_SENSOR_SCLK, G_SENSOR_SDI;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire VGA_HS, VGA_VS, lora_tx, uart_tx;

    // 50 MHz board clock (period = 20 ns)
    always #10 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk           (clk),
        .KEY           (KEY),
        .SW            (SW),
        .LEDR          (LEDR),
        .HEX0          (HEX0),
        .HEX1          (HEX1),
        .HEX2          (HEX2),
        .HEX3          (HEX3),
        .HEX4          (HEX4),
        .HEX5          (HEX5),
        .G_SENSOR_CS_N (G_SENSOR_CS_N),
        .G_SENSOR_INT  (G_SENSOR_INT),
        .G_SENSOR_SCLK (G_SENSOR_SCLK),
        .G_SENSOR_SDI  (G_SENSOR_SDI),
        .G_SENSOR_SDO  (G_SENSOR_SDO),
        .VGA_R         (VGA_R),
        .VGA_G         (VGA_G),
        .VGA_B         (VGA_B),
        .VGA_HS        (VGA_HS),
        .VGA_VS        (VGA_VS),
        .lora_tx       (lora_tx),
        .lora_rx       (lora_rx),
        .lora_aux      (lora_aux),
        .uart_tx       (uart_tx),
        .uart_rx       (uart_rx)
    );

    // Watchdog (500 us)
    initial begin
        #500000;
        $display("FATAL: tb_soc_adc_v2_integration timed out");
        $fatal(1);
    end

    task check(input condition, input [8*128-1:0] msg);
        begin
            if (!condition) begin
                $display("FAIL: %0s (time=%0t)", msg, $time);
                $fatal(1);
            end
        end
    endtask

    reg [31:0] drive_haddr = 0;
    reg [31:0] drive_hwdata = 0;
    reg [1:0]  drive_htrans = 0;
    reg        drive_hwrite = 0;

    task ahb_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            drive_haddr  = addr;
            drive_hwdata = data;
            drive_htrans = 2'b10; // NONSEQ
            drive_hwrite = 1'b1;
            @(posedge clk);
            @(negedge clk);
            drive_htrans = 2'b00;
            drive_hwrite = 1'b0;
            @(posedge clk);
            while (dut.HREADY !== 1'b1) @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask

    task ahb_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(negedge clk);
            drive_haddr  = addr;
            drive_htrans = 2'b10; // NONSEQ
            drive_hwrite = 1'b0;
            @(posedge clk);
            @(negedge clk);
            drive_htrans = 2'b00;
            @(posedge clk);
            while (dut.HREADY !== 1'b1) @(posedge clk);
            rdata = dut.HRDATA;
            @(negedge clk);
            #1;
        end
    endtask

    reg [31:0] read_val;
    reg [11:0] ch1_sample_1, ch2_sample_1;
    reg [11:0] ch1_sample_2, ch2_sample_2;

    initial begin
        $display("=== Starting tb_soc_adc_v2_integration ===");

        force dut.HADDR  = drive_haddr;
        force dut.HWDATA = drive_hwdata;
        force dut.HTRANS = drive_htrans;
        force dut.HWRITE = drive_hwrite;
        force dut.HSIZE  = 3'b010; // 32-bit word

        // 1. Reset cycle
        force dut.PRESETN_SYS = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        force dut.PRESETN_SYS = 1'b1;

        // Wait for synchronized ADC project reset release
        wait (dut.adc_project_reset_n === 1'b1);
        repeat (10) @(posedge clk);
        $display("[PASS] Reset synchronized deassertion observed");

        // 2. Verify initial quiescent state
        check(dut.adc_command_valid == 1'b0, "zero Qsys commands before enable");
        check(dut.adc_enable_req == 1'b0, "adc_enable_req is 0 initially");
        ahb_read(32'h4005_0010, read_val); // ADC_STATUS
        check(read_val == 32'd0, "STATUS is 0 initially (bit 6 strictly 0)");
        $display("[PASS] Initial quiescent state confirmed");

        // 3. Enable ADC via APB v2 ADC_CTRL
        ahb_write(32'h4005_000C, 32'h1); // ENABLE=1
        $display("[PASS] APB ENABLE=1 written to ADC_CTRL");

        // Wait for first publication to arrive in LIVE bank
        // Poll STATUS until NEW_FRAME (bit 4) is set
        read_val = 32'd0;
        while (!read_val[4]) begin
            ahb_read(32'h4005_0010, read_val);
            repeat (5) @(posedge clk);
        end
        check(read_val[2] == 1'b1, "LIVE_VALID is 1");
        check(read_val[4] == 1'b1, "NEW_FRAME is 1");
        $display("[PASS] Frame 1 published to LIVE bank (LIVE_VALID=1, NEW_FRAME=1)");

        // Read LIVE bank registers
        ahb_read(32'h4005_0034, read_val); // LIVE_SEQ
        check(read_val == 32'd1, "LIVE_SEQ == 1");
        ahb_read(32'h4005_0038, read_val); // LIVE_VALID_MASK
        check(read_val == 32'd3, "LIVE_VALID_MASK == 3");

        // 4. Atomic CAPTURE into HOLD bank
        ahb_write(32'h4005_000C, 32'h3); // ENABLE=1 | CAPTURE=1
        $display("[PASS] CAPTURE written to ADC_CTRL");

        // Verify HOLD bank populated
        ahb_read(32'h4005_0010, read_val); // STATUS
        check(read_val[3] == 1'b1, "HOLD_VALID == 1");

        ahb_read(32'h4005_0014, read_val); // FRAME_SEQ
        check(read_val >= 32'd1, "HOLD FRAME_SEQ >= 1");
        ahb_read(32'h4005_0018, read_val); // VALID_MASK
        check(read_val == 32'd3, "HOLD VALID_MASK == 3");

        ahb_read(32'h4005_001C, read_val); // CH1_RAW
        ch1_sample_1 = read_val[11:0];
        check(ch1_sample_1 != 12'd0, "CH1_RAW has non-zero Qsys sample");

        ahb_read(32'h4005_0020, read_val); // CH2_RAW
        ch2_sample_1 = read_val[11:0];
        check(ch2_sample_1 != 12'd0, "CH2_RAW has non-zero Qsys sample");

        $display("[PASS] Frame 1 captured: CH1=0x%03h, CH2=0x%03h", ch1_sample_1, ch2_sample_1);

        // 5. Disable & Quiesce: Verify LIVE invalidation and HOLD preservation
        ahb_write(32'h4005_000C, 32'h0); // ENABLE=0
        $display("[PASS] APB ENABLE=0 written");

        // Wait for engine disabled acknowledgement in PCLK
        while (dut.adc_engine_enabled_pclk) @(posedge clk);
        repeat (10) @(posedge clk);

        // Check STATUS: LIVE_VALID=0, NEW_FRAME=0, HOLD_VALID=1
        ahb_read(32'h4005_0010, read_val);
        check(read_val[2] == 1'b0, "LIVE_VALID invalidated upon quiesce");
        check(read_val[4] == 1'b0, "NEW_FRAME is 0 upon quiesce");
        check(read_val[3] == 1'b1, "HOLD_VALID preserved across disable");

        // Verify HOLD data unchanged
        ahb_read(32'h4005_001C, read_val);
        check(read_val[11:0] == ch1_sample_1, "HOLD CH1 preserved across disable");
        ahb_read(32'h4005_0020, read_val);
        check(read_val[11:0] == ch2_sample_1, "HOLD CH2 preserved across disable");
        $display("[PASS] Disable invalidation and HOLD preservation verified");

        // 6. Re-enable & Capture Frame 2
        ahb_write(32'h4005_000C, 32'h1); // ENABLE=1
        $display("[PASS] Re-enabled ADC");

        // Poll for Frame 2 publication
        read_val = 32'd0;
        while (!read_val[4]) begin
            ahb_read(32'h4005_0010, read_val);
            repeat (5) @(posedge clk);
        end
        check(read_val[2] == 1'b1, "LIVE_VALID asserted for Frame 2");
        check(read_val[4] == 1'b1, "NEW_FRAME asserted for Frame 2");

        // Capture Frame 2
        ahb_write(32'h4005_000C, 32'h3); // CAPTURE
        ahb_read(32'h4005_0014, read_val); // FRAME_SEQ
        check(read_val >= 32'd2, "HOLD FRAME_SEQ updated to >= 2");
        ahb_read(32'h4005_001C, read_val);
        ch1_sample_2 = read_val[11:0];
        $display("[PASS] Frame 2 captured: seq=2, CH1=0x%03h", ch1_sample_2);

        // 7. Error CDC & Sticky ERROR_STATUS test
        // Verify ERROR_STATUS is initially 0
        ahb_read(32'h4005_0064, read_val);
        check(read_val == 32'd0, "ERROR_STATUS initially 0");

        // Inject PACKET_ERROR (bit 3) via engine error_event in adc_sys_clk domain
        @(posedge dut.adc_sys_clk);
        force dut.u_adc_acquisition_engine.error_event = 4'b1000;
        @(posedge dut.adc_sys_clk);
        release dut.u_adc_acquisition_engine.error_event;

        // Wait for CDC toggle to cross into PCLK
        repeat (20) @(posedge clk);

        // Read STATUS and ERROR_STATUS
        ahb_read(32'h4005_0010, read_val); // STATUS
        check(read_val[7] == 1'b1, "STATUS[7] ERROR_PENDING asserted");
        ahb_read(32'h4005_0064, read_val); // ERROR_STATUS
        check(read_val[3] == 1'b1, "ERROR_STATUS[3] PACKET_ERROR set sticky");

        // Clear error via APB CLEAR_ERROR (bit 2)
        ahb_write(32'h4005_000C, 32'h5); // ENABLE=1 | CLEAR_ERROR=1
        ahb_read(32'h4005_0064, read_val);
        check(read_val == 32'd0, "ERROR_STATUS cleared to 0");
        ahb_read(32'h4005_0010, read_val);
        check(read_val[7] == 1'b0, "STATUS[7] cleared to 0");
        $display("[PASS] Error CDC transfer, sticky ERROR_STATUS, and CLEAR_ERROR verified");

        $display("SUMMARY: PASS tb_soc_adc_v2_integration");
        $finish;
    end

endmodule
