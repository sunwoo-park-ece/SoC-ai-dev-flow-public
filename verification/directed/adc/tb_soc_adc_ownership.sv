`timescale 1ns/1ps

// =============================================================================
// C1 Directed Integration Testbench: tb_soc_adc_ownership
//
// Verification Authority: Issue #6 [P11C-C1 TASK], spec/15_adc_joystick.md,
//                         spec/06_reset_clock.md, spec/05_apb_subsystem.md
//
// Proves externally observable C1 behavior without using internal FSM states:
//   1. No ADC command before synchronized ADC reset release.
//   2. No command before enable request reaches engine (free-running sequencer eliminated).
//   3. First accepted command is CH1 (5'd1) with single-cycle packet framing.
//   4. Next accepted command is CH2 (5'd2) following valid CH1 response.
//   5. Real Qsys response returns through engine.
//   6. Complete CH1+CH2 scan produces one mailbox/PCLK publication with exact payload.
//   7. Disable stops new command issue after drain/quiesce.
//   8. Re-enable cleanly restarts scan from CH1.
//   9. No old sequencer-generated command can appear at any time.
// =============================================================================

module tb_soc_adc_ownership;
    reg clk = 1'b0;
    reg [1:0] KEY = 2'b10;
    reg [9:0] SW = 10'b0;
    reg [2:1] G_SENSOR_INT = 2'b0;
    reg G_SENSOR_SDO = 1'b0;
    reg lora_rx = 1'b1;
    reg lora_aux = 1'b0;
    reg uart_rx = 1'b1;

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

    // Watchdog timer (500 us)
    initial begin
        #500000;
        $display("FATAL: tb_soc_adc_ownership timed out");
        $fatal(1);
    end

    task automatic check_condition(input condition, input [8*128-1:0] message);
        begin
            if (!condition) begin
                $display("FAIL: %0s (time=%0t)", message, $time);
                $fatal(1);
            end
        end
    endtask

    reg [31:0] drive_haddr = 32'h0;
    reg [31:0] drive_hwdata = 32'h0;
    reg [1:0]  drive_htrans = 2'b00;
    reg        drive_hwrite = 1'b0;

    task ahb_write_adc_ctrl(input [31:0] ctrl_val);
        begin
            @(negedge clk);
            drive_haddr  = 32'h4005_000C; // ADC_CTRL / ADDR_CTRL
            drive_hwdata = ctrl_val;
            drive_htrans = 2'b10;        // NONSEQ
            drive_hwrite = 1'b1;

            @(posedge clk);
            @(negedge clk);
            drive_htrans = 2'b00;        // IDLE for next address phase
            drive_hwrite = 1'b0;

            @(posedge clk);
            while (dut.HREADY !== 1'b1) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // Command transaction logging in adc_sys_clk domain
    integer cmd_count = 0;
    reg [4:0] logged_channels [0:31];
    reg       logged_sop [0:31];
    reg       logged_eop [0:31];

    always @(posedge dut.adc_sys_clk) begin
        if (dut.adc_project_reset_n && dut.adc_command_valid && dut.adc_command_ready) begin
            logged_channels[cmd_count] <= dut.adc_command_channel;
            logged_sop[cmd_count]      <= dut.adc_command_startofpacket;
            logged_eop[cmd_count]      <= dut.adc_command_endofpacket;
            cmd_count                  <= cmd_count + 1;
        end
    end

    // Frame pulse logging in PCLK domain
    integer pulse_count = 0;
    reg [31:0] last_frame_seq = 0;
    reg [5:0]  last_valid_mask = 0;
    reg [71:0] last_samples_flat = 0;

    always @(posedge clk) begin
        if (dut.adc_frame_pulse_pclk) begin
            pulse_count       <= pulse_count + 1;
            last_frame_seq    <= dut.adc_frame_seq_pclk;
            last_valid_mask   <= dut.adc_valid_mask_pclk;
            last_samples_flat <= dut.adc_samples_flat_pclk;
        end
    end

    integer disabled_cmd_snap = 0;

    initial begin
        $display("=== Starting tb_soc_adc_ownership ===");

        // Hold system reset initially
        force dut.PRESETN_SYS = 1'b0;
        force dut.HADDR  = drive_haddr;
        force dut.HWRITE = drive_hwrite;
        force dut.HTRANS = drive_htrans;
        force dut.HSIZE  = 3'b010;
        force dut.HWDATA = drive_hwdata;

        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // Check 1: No ADC command before synchronized ADC reset release
        // ---------------------------------------------------------------------
        check_condition(dut.adc_project_reset_n === 1'b0, "adc_project_reset_n not asserted in reset");
        check_condition(dut.adc_command_valid === 1'b0, "adc_command_valid asserted during reset!");

        // Release system reset
        @(negedge clk);
        force dut.PRESETN_SYS = 1'b1;

        // Wait for adc_project_reset_n to deassert (2 adc_sys_clk edges)
        wait (dut.adc_project_reset_n === 1'b1);
        $display("[PASS] Reset synchronized deassertion observed");

        // ---------------------------------------------------------------------
        // Check 2: No command before enable request reaches engine
        // Proves historical free-running scanner is completely eliminated!
        // ---------------------------------------------------------------------
        repeat (20) begin
            @(posedge dut.adc_sys_clk);
            check_condition(dut.adc_command_valid === 1'b0,
                "Old scanner behavior detected: command issued without enable!");
            check_condition(dut.adc_engine_enabled === 1'b0,
                "Engine enabled prematurely without enable_req!");
        end
        check_condition(dut.adc_engine_enabled_pclk === 1'b0,
            "Engine enabled PCLK status asserted without enable_req!");
        check_condition(cmd_count == 0, "Commands observed while disabled!");
        $display("[PASS] Check 1 & 2: Quiescent state confirmed before enable");

        // ---------------------------------------------------------------------
        // Enable ADC via APB write to 0x4005_000C (bit 0 = 1)
        // ---------------------------------------------------------------------
        ahb_write_adc_ctrl(32'h0000_0001);
        check_condition(dut.adc_enable_req === 1'b1, "adc_enable_req not set after APB write");

        // Wait for at least 2 complete commands (CH1 and CH2)
        wait (cmd_count >= 2);
        $display("[PASS] First 2 commands accepted by Qsys");

        // Check 3: First accepted command is CH1 (5'd1) with SOP=1, EOP=1
        check_condition(logged_channels[0] === 5'd1, "First command channel was not CH1!");
        check_condition(logged_sop[0] === 1'b1, "First command SOP was not 1!");
        check_condition(logged_eop[0] === 1'b1, "First command EOP was not 1!");
        $display("[PASS] Check 3: First accepted command is CH1 (5'd1) single packet");

        // Check 4: Next accepted command is CH2 (5'd2) with SOP=1, EOP=1
        check_condition(logged_channels[1] === 5'd2, "Second command channel was not CH2!");
        check_condition(logged_sop[1] === 1'b1, "Second command SOP was not 1!");
        check_condition(logged_eop[1] === 1'b1, "Second command EOP was not 1!");
        $display("[PASS] Check 4: Second accepted command is CH2 (5'd2) single packet");

        // ---------------------------------------------------------------------
        // Check 5 & 6: Real Qsys response returns through engine and publishes to PCLK
        // ---------------------------------------------------------------------
        wait (pulse_count >= 1);
        check_condition(last_frame_seq === 32'd1, "PCLK frame sequence is not 1!");
        check_condition(last_valid_mask === 6'b000011, "PCLK valid mask is not 6'b000011!");
        check_condition(last_samples_flat[11:0] === 12'h600, "CH1 sample in PCLK frame mismatch!");
        check_condition(last_samples_flat[23:12] === 12'hA00, "CH2 sample in PCLK frame mismatch!");
        check_condition(last_samples_flat[71:24] === 48'd0, "CH3..CH6 samples not baseline 0!");
        $display("[PASS] Check 5 & 6: Frame 1 successfully published to PCLK with real Qsys samples");

        // ---------------------------------------------------------------------
        // Check 7: Disable stops new command issue after drain/quiesce
        // ---------------------------------------------------------------------
        ahb_write_adc_ctrl(32'h0000_0000);
        check_condition(dut.adc_enable_req === 1'b0, "adc_enable_req not cleared after APB write");

        wait (dut.adc_engine_enabled === 1'b0);
        wait (dut.adc_engine_enabled_pclk === 1'b0);
        $display("[PASS] Engine acknowledges disabled state to PCLK domain");

        disabled_cmd_snap = cmd_count;

        // Verify that after becoming quiescent, no further commands are issued
        repeat (30) begin
            @(posedge dut.adc_sys_clk);
            check_condition(dut.adc_command_valid === 1'b0, "Command issued after disable quiescent!");
        end
        check_condition(cmd_count == disabled_cmd_snap, "New command accepted while disabled!");
        $display("[PASS] Check 7: Disable stops command issuance cleanly; zero commands while disabled");

        // ---------------------------------------------------------------------
        // Check 8: Re-enable cleanly restarts at CH1
        // ---------------------------------------------------------------------
        ahb_write_adc_ctrl(32'h0000_0001);
        wait (dut.adc_engine_enabled === 1'b1);

        wait (cmd_count > disabled_cmd_snap);
        check_condition(logged_channels[disabled_cmd_snap] === 5'd1,
            "Re-enable did not restart at CH1!");
        $display("[PASS] Check 8: Re-enable restarts cleanly at CH1");

        // Allow second frame to complete
        wait (pulse_count >= 2);
        check_condition(last_frame_seq === 32'd2, "PCLK frame sequence is not 2 on second frame!");
        check_condition(last_valid_mask === 6'b000011, "PCLK valid mask mismatch on second frame!");
        $display("[PASS] Frame 2 successfully published to PCLK domain");

        // Disable again and confirm clean finish
        ahb_write_adc_ctrl(32'h0000_0000);
        wait (dut.adc_engine_enabled === 1'b0);
        wait (dut.adc_engine_enabled_pclk === 1'b0);

        repeat (20) @(posedge clk);
        $display("SUMMARY: PASS C1 SoC ADC ownership cutover");
        $finish;
    end
endmodule
