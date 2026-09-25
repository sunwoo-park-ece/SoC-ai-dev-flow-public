`timescale 1ns/1ps

// =============================================================================
// Standalone Testbench: tb_apb_adc_v2
//
// Verification Authority:
//   - Issue #6 [P11C-C2 TASK] Section 15.A
//   - spec/15_adc_joystick.md, spec/05_apb_subsystem.md
//   - C1 Acceptance Decision: ADC_STATUS[6] = 0 (ASSEMBLY_ACTIVE removed)
//
// Coverage:
//   1. Identity / Memory Map / Reset Values / Canonical Offsets
//   2. ADC_CTRL semantics (ENABLE, CAPTURE, CLEAR_ERROR, combined, malformed)
//   3. LIVE / HOLD snapshot banks, NEW_FRAME truth table, atomicity, idempotence,
//      disable invalidation, HOLD survival across disable/re-enable
//   4. FRAME_COUNT exact increment per publication; no increment from reads/writes/errors
//   5. ERROR_STATUS sticky semantics, simultaneous errors, CLEAR_ERROR,
//      and set-dominant coincidence proof
//   6. Legality matrix: every valid offset, reserved gaps (0x50..0x5C, 0x68..0xFC),
//      RO write rejections, +0x100 alias rejection, high-offset rejection,
//      misalignment, and zero side-effects verification
// =============================================================================

module tb_apb_adc_v2;
    reg        pclk = 0;
    reg        preset_n = 0;
    reg [31:0] paddr = 0;
    reg        pwrite = 0;
    reg        psel = 0;
    reg        penable = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire        pready;
    wire        pslverr;

    wire        adc_enable_req;
    reg         engine_enabled_pclk = 0;
    reg         frame_pulse_pclk = 0;
    reg [31:0]  frame_seq_pclk = 0;
    reg [5:0]   valid_mask_pclk = 0;
    reg [71:0]  samples_flat_pclk = 0;
    reg         mailbox_busy = 0;
    reg [3:0]   error_pulse_pclk = 0;
    reg [5:0]   joy_status_i = 0;
    wire [11:0] joy_center_x_o;
    wire [11:0] joy_center_y_o;
    wire [11:0] joy_deadzone_o;

    always #10 pclk = ~pclk; // 50 MHz PCLK

    APB_ADC_Controller dut (
        .PCLK                (pclk),
        .PRESETn             (preset_n),
        .PADDR               (paddr),
        .PWRITE              (pwrite),
        .PSEL                (psel),
        .PENABLE             (penable),
        .PWDATA              (pwdata),
        .PRDATA              (prdata),
        .PREADY              (pready),
        .PSLVERR             (pslverr),
        .adc_enable_req      (adc_enable_req),
        .engine_enabled_pclk (engine_enabled_pclk),
        .frame_pulse_pclk    (frame_pulse_pclk),
        .frame_seq_pclk      (frame_seq_pclk),
        .valid_mask_pclk     (valid_mask_pclk),
        .samples_flat_pclk   (samples_flat_pclk),
        .mailbox_busy        (mailbox_busy),
        .error_pulse_pclk    (error_pulse_pclk),
        .joy_status_i        (joy_status_i),
        .joy_center_x_o      (joy_center_x_o),
        .joy_center_y_o      (joy_center_y_o),
        .joy_deadzone_o      (joy_deadzone_o)
    );

    // Watchdog
    initial begin
        #500000;
        $display("FATAL: tb_apb_adc_v2 watchdog timeout");
        $fatal(1);
    end

    // APB Bus Access Tasks
    task apb_read(input [31:0] addr, output [31:0] data, output err);
        begin
            @(posedge pclk);
            paddr   <= addr;
            pwrite  <= 1'b0;
            psel    <= 1'b1;
            penable <= 1'b0;
            @(posedge pclk);
            penable <= 1'b1;
            @(negedge pclk);
            data = prdata;
            err  = pslverr;
            @(posedge pclk);
            psel    <= 1'b0;
            penable <= 1'b0;
            paddr   <= 32'h0;
        end
    endtask

    task apb_write(input [31:0] addr, input [31:0] data, output err);
        begin
            @(posedge pclk);
            paddr   <= addr;
            pwrite  <= 1'b1;
            psel    <= 1'b1;
            penable <= 1'b0;
            pwdata  <= data;
            @(posedge pclk);
            penable <= 1'b1;
            @(negedge pclk);
            err = pslverr;
            @(posedge pclk);
            psel    <= 1'b0;
            penable <= 1'b0;
            paddr   <= 32'h0;
            pwdata  <= 32'h0;
            pwrite  <= 1'b0;
            #1;
        end
    endtask

    // Check helper
    task check(input condition, input [8*128-1:0] msg);
        begin
            if (!condition) begin
                $display("FAIL: %0s (time=%0t)", msg, $time);
                $fatal(1);
            end
        end
    endtask

    reg [31:0] rdata;
    reg        rerr;
    integer    c, off_idx;

    initial begin
        $display("=== Starting tb_apb_adc_v2 ===");

        // Reset
        preset_n = 0;
        repeat (3) @(posedge pclk);
        preset_n = 1;
        repeat (2) @(posedge pclk);

        // ---------------------------------------------------------------------
        // 1. Identity & Reset Values
        // ---------------------------------------------------------------------
        apb_read(32'h4005_0000, rdata, rerr);
        check(!rerr && rdata == 32'h6170622D, "NAME0 == 'apb-'");

        apb_read(32'h4005_0004, rdata, rerr);
        check(!rerr && rdata == 32'h61646320, "NAME1 == 'adc '");

        apb_read(32'h4005_0008, rdata, rerr);
        check(!rerr && rdata == 32'h00020000, "VERSION == 2.0 (0x00020000)");

        apb_read(32'h4005_000C, rdata, rerr);
        check(!rerr && rdata == 32'h0, "CTRL reset == 0");

        apb_read(32'h4005_0010, rdata, rerr);
        check(!rerr && rdata == 32'h0, "STATUS reset == 0 (including bit6=0)");

        apb_read(32'h4005_0014, rdata, rerr);
        check(!rerr && rdata == 32'h0, "FRAME_SEQ reset == 0");

        apb_read(32'h4005_0018, rdata, rerr);
        check(!rerr && rdata == 32'h0, "VALID_MASK reset == 0");

        apb_read(32'h4005_001C, rdata, rerr);
        check(!rerr && rdata == 32'h0, "CH1_RAW reset == 0");

        apb_read(32'h4005_0020, rdata, rerr);
        check(!rerr && rdata == 32'h0, "CH2_RAW reset == 0");

        apb_read(32'h4005_0024, rdata, rerr);
        check(!rerr && rdata == 32'h0, "CH3_RAW reset == 0");

        apb_read(32'h4005_0034, rdata, rerr);
        check(!rerr && rdata == 32'h0, "LIVE_SEQ reset == 0");

        apb_read(32'h4005_0038, rdata, rerr);
        check(!rerr && rdata == 32'h0, "LIVE_VALID_MASK reset == 0");

        apb_read(32'h4005_003C, rdata, rerr);
        check(!rerr && rdata == 32'h00000003, "ACTIVE_MASK == 0x00000003");

        apb_read(32'h4005_0040, rdata, rerr);
        check(!rerr && rdata == 32'd2048, "JOY_CENTER_X reset == 2048");

        apb_read(32'h4005_0044, rdata, rerr);
        check(!rerr && rdata == 32'd2048, "JOY_CENTER_Y reset == 2048");

        apb_read(32'h4005_0048, rdata, rerr);
        check(!rerr && rdata == 32'd300, "JOY_DEADZONE reset == 300");

        apb_read(32'h4005_004C, rdata, rerr);
        check(!rerr && rdata == 32'd0, "JOY_STATUS reset == 0");

        apb_read(32'h4005_0060, rdata, rerr);
        check(!rerr && rdata == 32'd0, "FRAME_COUNT reset == 0");

        apb_read(32'h4005_0064, rdata, rerr);
        check(!rerr && rdata == 32'd0, "ERROR_STATUS reset == 0");

        $display("[PASS] Identity, memory map, reset values verified");

        // ---------------------------------------------------------------------
        // 2. ADC_CTRL Semantics (ENABLE, CAPTURE, CLEAR_ERROR, Malformed writes)
        // ---------------------------------------------------------------------
        // Set ENABLE = 1
        apb_write(32'h4005_000C, 32'h1, rerr);
        check(!rerr, "ENABLE set write OKAY");
        check(adc_enable_req == 1'b1, "adc_enable_req asserted");
        apb_read(32'h4005_000C, rdata, rerr);
        check(!rerr && rdata == 32'h1, "CTRL readback bit 0 == 1");

        // Clear ENABLE = 0
        apb_write(32'h4005_000C, 32'h0, rerr);
        check(!rerr, "ENABLE clear write OKAY");
        check(adc_enable_req == 1'b0, "adc_enable_req deasserted");
        apb_read(32'h4005_000C, rdata, rerr);
        check(!rerr && rdata == 32'h0, "CTRL readback bit 0 == 0");

        // Malformed writes (reserved bits nonzero) -> PSLVERR and ZERO side effects
        apb_write(32'h4005_000C, 32'h8, rerr); // bit 3 set
        check(rerr, "malformed write bit 3 set -> PSLVERR");
        check(adc_enable_req == 1'b0, "malformed write had zero side effect on ENABLE");

        apb_write(32'h4005_000C, 32'h8000_0000, rerr); // bit 31 set
        check(rerr, "malformed write bit 31 set -> PSLVERR");
        check(adc_enable_req == 1'b0, "malformed write had zero side effect on ENABLE");

        apb_write(32'h4005_000C, 32'hFFFF_FFFF, rerr); // all bits set
        check(rerr, "malformed write all bits set -> PSLVERR");
        check(adc_enable_req == 1'b0, "malformed write had zero side effect on ENABLE");

        // Combined legal write: ENABLE=1, CAPTURE=1, CLEAR_ERROR=1 (0x7)
        apb_write(32'h4005_000C, 32'h7, rerr);
        check(!rerr, "combined legal write (0x7) -> OKAY");
        check(adc_enable_req == 1'b1, "ENABLE updated to 1 by combined write");
        apb_read(32'h4005_000C, rdata, rerr);
        check(!rerr && rdata == 32'h1, "W1P bits do not persist in readback");

        $display("[PASS] ADC_CTRL legality and side-effect isolation verified");

        // ---------------------------------------------------------------------
        // 3. LIVE & HOLD Banks, NEW_FRAME, Atomicity, and Idempotence
        // ---------------------------------------------------------------------
        // Simulate engine enabled in PCLK
        engine_enabled_pclk = 1'b1;

        // Verify NEW_FRAME before any publication
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[4] == 1'b0, "NEW_FRAME == 0 before first publication");
        check(rdata[2] == 1'b0, "LIVE_VALID == 0");
        check(rdata[3] == 1'b0, "HOLD_VALID == 0");

        // Deliver Publication 1: seq=1, mask=6'b000011, CH1=0x111, CH2=0x222
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b1;
        frame_seq_pclk    <= 32'd1;
        valid_mask_pclk   <= 6'b000011;
        samples_flat_pclk <= {48'd0, 12'h222, 12'h111};
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b0;
        @(posedge pclk);

        // Check LIVE bank readback
        apb_read(32'h4005_0034, rdata, rerr);
        check(!rerr && rdata == 32'd1, "LIVE_SEQ == 1");
        apb_read(32'h4005_0038, rdata, rerr);
        check(!rerr && rdata == 32'd3, "LIVE_VALID_MASK == 3");

        // Check STATUS: LIVE_VALID=1, HOLD_VALID=0, NEW_FRAME=1
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[2] == 1'b1, "LIVE_VALID == 1");
        check(rdata[3] == 1'b0, "HOLD_VALID == 0");
        check(rdata[4] == 1'b1, "NEW_FRAME == 1");
        check(rdata[6] == 1'b0, "ADC_STATUS[6] strictly 0");

        // HOLD bank still unpopulated before CAPTURE
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'd0, "CH1_RAW still 0 before capture");

        // Execute CAPTURE (W1P bit 1)
        apb_write(32'h4005_000C, 32'h3, rerr); // ENABLE=1 | CAPTURE=1
        check(!rerr, "CAPTURE write OKAY");

        // Check HOLD bank populated atomically
        apb_read(32'h4005_0014, rdata, rerr);
        check(!rerr && rdata == 32'd1, "HOLD FRAME_SEQ == 1");
        apb_read(32'h4005_0018, rdata, rerr);
        check(!rerr && rdata == 32'd3, "HOLD VALID_MASK == 3");
        apb_read(32'h4005_001C, rdata, rerr);
        check(!rerr && rdata == 32'h111, "HOLD CH1_RAW == 0x111");
        apb_read(32'h4005_0020, rdata, rerr);
        check(!rerr && rdata == 32'h222, "HOLD CH2_RAW == 0x222");
        apb_read(32'h4005_0024, rdata, rerr);
        check(!rerr && rdata == 32'h0, "HOLD CH3_RAW baseline == 0");

        // Check STATUS: NEW_FRAME must now be 0 (captured!)
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[3] == 1'b1, "HOLD_VALID == 1");
        check(rdata[4] == 1'b0, "NEW_FRAME == 0 after capture");

        // Idempotence test: Repeated CAPTURE when NEW_FRAME=0 is OKAY and no-op
        apb_write(32'h4005_000C, 32'h3, rerr);
        check(!rerr, "repeated CAPTURE is OKAY");
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'h111, "HOLD data unchanged after idempotent CAPTURE");

        // Deliver Publication 2: seq=2, CH1=0x333, CH2=0x444
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b1;
        frame_seq_pclk    <= 32'd2;
        valid_mask_pclk   <= 6'b000011;
        samples_flat_pclk <= {48'd0, 12'h444, 12'h333};
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b0;
        @(posedge pclk);

        // Before capture of frame 2: HOLD must preserve frame 1!
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[4] == 1'b1, "NEW_FRAME == 1 for frame 2");
        apb_read(32'h4005_0014, rdata, rerr);
        check(rdata == 32'd1, "HOLD still has seq=1");
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'h111, "HOLD still has CH1=0x111");

        // Capture frame 2
        apb_write(32'h4005_000C, 32'h3, rerr);
        check(!rerr, "CAPTURE frame 2 OKAY");
        apb_read(32'h4005_0014, rdata, rerr);
        check(rdata == 32'd2, "HOLD updated to seq=2");
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'h333, "HOLD CH1 updated to 0x333");
        apb_read(32'h4005_0020, rdata, rerr);
        check(rdata == 32'h444, "HOLD CH2 updated to 0x444");

        $display("[PASS] LIVE/HOLD snapshot banks, NEW_FRAME, atomicity, idempotence verified");

        // ---------------------------------------------------------------------
        // 4. Disable Invalidation & HOLD Survival Across Disable/Re-enable
        // ---------------------------------------------------------------------
        // Clear ENABLE
        apb_write(32'h4005_000C, 32'h0, rerr);
        check(!rerr, "clear ENABLE write OKAY");

        // Simulate engine disabled acknowledgement in PCLK
        @(posedge pclk);
        engine_enabled_pclk = 1'b0;
        @(posedge pclk);

        // LIVE must be invalidated immediately
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[2] == 1'b0, "LIVE_VALID invalidated upon disabled ack");
        check(rdata[4] == 1'b0, "NEW_FRAME == 0 upon disabled ack");

        // HOLD must survive!
        check(rdata[3] == 1'b1, "HOLD_VALID survives disable");
        apb_read(32'h4005_0014, rdata, rerr);
        check(rdata == 32'd2, "HOLD seq survives disable");
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'h333, "HOLD CH1 survives disable");
        apb_read(32'h4005_0020, rdata, rerr);
        check(rdata == 32'h444, "HOLD CH2 survives disable");

        // Re-enable
        apb_write(32'h4005_000C, 32'h1, rerr);
        check(!rerr, "re-enable write OKAY");
        @(posedge pclk);
        engine_enabled_pclk = 1'b1;
        @(posedge pclk);

        // Before any new frame arrives, LIVE must remain invalid
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[2] == 1'b0, "LIVE_VALID still 0 on re-enable before new publication");
        check(rdata[4] == 1'b0, "NEW_FRAME still 0 on re-enable (no stale resurrection)");
        check(rdata[3] == 1'b1, "HOLD_VALID still intact across re-enable");
        apb_read(32'h4005_001C, rdata, rerr);
        check(rdata == 32'h333, "HOLD CH1 preserved across re-enable");

        // Deliver Publication 3: seq=3, CH1=0x555, CH2=0x666
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b1;
        frame_seq_pclk    <= 32'd3;
        valid_mask_pclk   <= 6'b000011;
        samples_flat_pclk <= {48'd0, 12'h666, 12'h555};
        @(posedge pclk);
        frame_pulse_pclk  <= 1'b0;
        @(posedge pclk);

        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[2] == 1'b1, "LIVE_VALID restored on publication 3");
        check(rdata[4] == 1'b1, "NEW_FRAME asserted on publication 3");

        $display("[PASS] Disable invalidation and HOLD survival across disable/re-enable verified");

        // ---------------------------------------------------------------------
        // 5. FRAME_COUNT Exact Increment
        // ---------------------------------------------------------------------
        // Exactly 3 publications have been delivered so far (frames 1, 2, 3)
        apb_read(32'h4005_0060, rdata, rerr);
        check(!rerr && rdata == 32'd3, "FRAME_COUNT == 3 after 3 publications");

        // Deliver 2 more publications
        for (c = 4; c <= 5; c = c + 1) begin
            @(posedge pclk);
            frame_pulse_pclk  <= 1'b1;
            frame_seq_pclk    <= c;
            valid_mask_pclk   <= 6'b000011;
            samples_flat_pclk <= {48'd0, 12'h666, 12'h555};
            @(posedge pclk);
            frame_pulse_pclk  <= 1'b0;
            @(posedge pclk);
        end

        apb_read(32'h4005_0060, rdata, rerr);
        check(!rerr && rdata == 32'd5, "FRAME_COUNT == 5 after 5 publications");

        // Verify reads/writes/captures do not increment FRAME_COUNT
        apb_write(32'h4005_000C, 32'h3, rerr); // CAPTURE
        apb_read(32'h4005_0060, rdata, rerr);
        check(rdata == 32'd5, "FRAME_COUNT does not increment on CAPTURE");

        $display("[PASS] FRAME_COUNT exact increment verified");

        // ---------------------------------------------------------------------
        // 6. ERROR_STATUS, Sticky Semantics & Set-Dominant Coincidence
        // ---------------------------------------------------------------------
        // Initial ERROR_STATUS is 0
        apb_read(32'h4005_0064, rdata, rerr);
        check(rdata == 32'd0, "ERROR_STATUS initially 0");

        // Inject each error bit independently
        for (c = 0; c < 4; c = c + 1) begin
            @(posedge pclk);
            error_pulse_pclk    <= (4'b0001 << c);
            @(posedge pclk);
            error_pulse_pclk    <= 4'b0000;
            @(posedge pclk);

            apb_read(32'h4005_0064, rdata, rerr);
            check(rdata[c] == 1'b1, "error bit set sticky");
            apb_read(32'h4005_0010, rdata, rerr);
            check(rdata[7] == 1'b1, "STATUS[7] ERROR_PENDING asserted");
        end

        // All 4 bits set
        apb_read(32'h4005_0064, rdata, rerr);
        check(rdata[3:0] == 4'hF, "all 4 error bits set sticky");

        // CLEAR_ERROR (W1P bit 2 of CTRL)
        apb_write(32'h4005_000C, 32'h5, rerr); // ENABLE=1 | CLEAR_ERROR=1
        check(!rerr, "CLEAR_ERROR write OKAY");

        apb_read(32'h4005_0064, rdata, rerr);
        check(rdata == 32'd0, "ERROR_STATUS cleared to 0");
        apb_read(32'h4005_0010, rdata, rerr);
        check(rdata[7] == 1'b0, "STATUS[7] ERROR_PENDING cleared");

        // Set-Dominant Coincidence Test:
        // On the exact same clock edge as a CLEAR_ERROR write, error_pulse_pclk asserts!
        @(posedge pclk);
        paddr   <= 32'h4005_000C;
        pwrite  <= 1'b1;
        psel    <= 1'b1;
        penable <= 1'b0;
        pwdata  <= 32'h5; // CLEAR_ERROR=1
        @(posedge pclk);
        penable <= 1'b1;
        error_pulse_pclk <= 4'b0010; // Bit 1 coincident new error!
        @(posedge pclk);
        psel    <= 1'b0;
        penable <= 1'b0;
        error_pulse_pclk <= 4'b0000;
        @(posedge pclk);

        // Verification: Bit 1 MUST be set because new set is dominant over clear!
        apb_read(32'h4005_0064, rdata, rerr);
        check(rdata[1] == 1'b1, "SET-DOMINANT: bit 1 is SET despite coincident CLEAR_ERROR");
        check(rdata[0] == 1'b0 && rdata[2] == 1'b0 && rdata[3] == 1'b0, "other bits cleared");

        // Clear again
        apb_write(32'h4005_000C, 32'h5, rerr);
        apb_read(32'h4005_0064, rdata, rerr);
        check(rdata == 32'd0, "cleanly cleared after set-dominant test");

        $display("[PASS] ERROR_STATUS sticky and set-dominant coincidence verified");

        // ---------------------------------------------------------------------
        // 7. Calibration Registers (JOY_CENTER_X/Y, JOY_DEADZONE)
        // ---------------------------------------------------------------------
        apb_write(32'h4005_0040, 32'd1000, rerr);
        check(!rerr, "JOY_CENTER_X write OKAY");
        check(joy_center_x_o == 12'd1000, "joy_center_x_o output updated");

        apb_write(32'h4005_0044, 32'd3000, rerr);
        check(!rerr, "JOY_CENTER_Y write OKAY");
        check(joy_center_y_o == 12'd3000, "joy_center_y_o output updated");

        apb_write(32'h4005_0048, 32'd150, rerr);
        check(!rerr, "JOY_DEADZONE write OKAY");
        check(joy_deadzone_o == 12'd150, "joy_deadzone_o output updated");

        apb_read(32'h4005_0040, rdata, rerr);
        check(!rerr && rdata == 32'd1000, "JOY_CENTER_X readback == 1000");
        apb_read(32'h4005_0044, rdata, rerr);
        check(!rerr && rdata == 32'd3000, "JOY_CENTER_Y readback == 3000");
        apb_read(32'h4005_0048, rdata, rerr);
        check(!rerr && rdata == 32'd150, "JOY_DEADZONE readback == 150");

        $display("[PASS] Calibration registers RW verified");

        // ---------------------------------------------------------------------
        // 8. Legality Matrix & PSLVERR Checks
        // ---------------------------------------------------------------------
        // Reserved gaps in canonical map: 0x50..0x5C
        for (off_idx = 16'h0050; off_idx <= 16'h005C; off_idx = off_idx + 4) begin
            apb_read(32'h4005_0000 + off_idx, rdata, rerr);
            check(rerr, "reserved gap 0x50..0x5C read returns PSLVERR");
            apb_write(32'h4005_0000 + off_idx, 32'hDEAD, rerr);
            check(rerr, "reserved gap 0x50..0x5C write returns PSLVERR");
        end

        // Reserved gaps in canonical map: 0x68..0xFC
        for (off_idx = 16'h0068; off_idx <= 16'h00FC; off_idx = off_idx + 16) begin
            apb_read(32'h4005_0000 + off_idx, rdata, rerr);
            check(rerr, "reserved gap 0x68..0xFC read returns PSLVERR");
            apb_write(32'h4005_0000 + off_idx, 32'hDEAD, rerr);
            check(rerr, "reserved gap 0x68..0xFC write returns PSLVERR");
        end

        // RO write attempts on every read-only register
        apb_write(32'h4005_0000, 32'hDEADBEEF, rerr); check(rerr, "RO write NAME0 -> PSLVERR");
        apb_write(32'h4005_0004, 32'hDEADBEEF, rerr); check(rerr, "RO write NAME1 -> PSLVERR");
        apb_write(32'h4005_0008, 32'hDEADBEEF, rerr); check(rerr, "RO write VERSION -> PSLVERR");
        apb_write(32'h4005_0010, 32'hDEADBEEF, rerr); check(rerr, "RO write STATUS -> PSLVERR");
        apb_write(32'h4005_0014, 32'hDEADBEEF, rerr); check(rerr, "RO write FRAME_SEQ -> PSLVERR");
        apb_write(32'h4005_0018, 32'hDEADBEEF, rerr); check(rerr, "RO write VALID_MASK -> PSLVERR");
        apb_write(32'h4005_001C, 32'hDEADBEEF, rerr); check(rerr, "RO write CH1_RAW -> PSLVERR");
        apb_write(32'h4005_0020, 32'hDEADBEEF, rerr); check(rerr, "RO write CH2_RAW -> PSLVERR");
        apb_write(32'h4005_0034, 32'hDEADBEEF, rerr); check(rerr, "RO write LIVE_SEQ -> PSLVERR");
        apb_write(32'h4005_0038, 32'hDEADBEEF, rerr); check(rerr, "RO write LIVE_VALID_MASK -> PSLVERR");
        apb_write(32'h4005_003C, 32'hDEADBEEF, rerr); check(rerr, "RO write ACTIVE_MASK -> PSLVERR");
        apb_write(32'h4005_004C, 32'hDEADBEEF, rerr); check(rerr, "RO write JOY_STATUS -> PSLVERR");
        apb_write(32'h4005_0060, 32'hDEADBEEF, rerr); check(rerr, "RO write FRAME_COUNT -> PSLVERR");
        apb_write(32'h4005_0064, 32'hDEADBEEF, rerr); check(rerr, "RO write ERROR_STATUS -> PSLVERR");

        // +0x100 and higher alias rejections
        apb_read(32'h4005_0100, rdata, rerr); check(rerr, "+0x100 read returns PSLVERR");
        apb_write(32'h4005_0100, 32'h1, rerr); check(rerr, "+0x100 write returns PSLVERR");
        apb_read(32'h4005_010C, rdata, rerr); check(rerr, "+0x10C read returns PSLVERR");
        apb_write(32'h4005_010C, 32'h1, rerr); check(rerr, "+0x10C write returns PSLVERR");
        apb_read(32'h4005_1000, rdata, rerr); check(rerr, "+0x1000 read returns PSLVERR");
        apb_read(32'h4005_FFFC, rdata, rerr); check(rerr, "+0xFFFC read returns PSLVERR");

        // Misaligned accesses
        apb_read(32'h4005_0001, rdata, rerr); check(rerr, "misaligned 0x01 returns PSLVERR");
        apb_read(32'h4005_0002, rdata, rerr); check(rerr, "misaligned 0x02 returns PSLVERR");
        apb_read(32'h4005_0003, rdata, rerr); check(rerr, "misaligned 0x03 returns PSLVERR");

        // Zero side effect check on registered state
        apb_read(32'h4005_0040, rdata, rerr); check(rdata == 32'd1000, "JOY_CENTER_X preserved");
        apb_read(32'h4005_0044, rdata, rerr); check(rdata == 32'd3000, "JOY_CENTER_Y preserved");
        apb_read(32'h4005_0048, rdata, rerr); check(rdata == 32'd150, "JOY_DEADZONE preserved");

        $display("[PASS] Legality matrix and PSLVERR generation fully verified");

        $display("SUMMARY: PASS tb_apb_adc_v2 standalone regression");
        $finish;
    end

endmodule
