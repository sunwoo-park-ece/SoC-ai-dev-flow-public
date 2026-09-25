`timescale 1ns/1ps

// =============================================================================
// Integration Testbench: tb_adc_engine_cdc_integration
//
// Verification Authority:
//   - Issue #6 [P11C-C2 REVIEW] Section 1 (Correction A)
//   - Preferred stronger proof:
//       adc_acquisition_engine
//               |
//               +--> error_event[3:0]
//               |
//       adc_error_event_cdc
//               |
//               +--> error_pulse_pclk[3:0]
//
// Requirements:
//   1. Drive command_ready=1 continuously (fastest legal acceptance by engine).
//   2. Drive adversarial malformed responses at the fastest legal behavior
//      accepted by the engine (1-cycle latency after command issue).
//   3. Measure actual source assertion cycle timestamps from the engine.
//   4. Measure and prove the true minimum same-bit error-event spacing.
//   5. Prove: source error event count == destination error pulse count.
//   6. Prove: zero duplicate destination pulses, zero lost destination pulses.
// =============================================================================

module tb_adc_engine_cdc_integration;

    reg        adc_sys_clk = 0;
    reg        adc_reset_n = 0;
    reg        enable = 0;
    wire       engine_enabled;

    wire       command_valid;
    wire [4:0] command_channel;
    wire       command_startofpacket;
    wire       command_endofpacket;
    reg        command_ready = 1;

    reg        response_valid = 0;
    reg [4:0]  response_channel = 0;
    reg [11:0] response_data = 0;
    reg        response_startofpacket = 0;
    reg        response_endofpacket = 0;

    wire        frame_valid;
    reg         frame_ready = 1;
    wire [31:0] frame_seq;
    wire [5:0]  valid_mask;
    wire [71:0] samples_flat;
    wire [3:0]  error_event;

    reg        pclk = 0;
    reg        pclk_reset_n = 0;
    wire [3:0] error_pulse_pclk;

    // Configurable clock periods
    real adc_clk_period = 40.0; // 25 MHz canonical adc_sys_clk
    real pclk_period = 20.0;    // 50 MHz PCLK

    always #(adc_clk_period / 2.0) adc_sys_clk = ~adc_sys_clk;
    always #(pclk_period / 2.0)    pclk = ~pclk;

    // DUT 1: P11B Frozen Acquisition Engine
    adc_acquisition_engine u_engine (
        .adc_sys_clk           (adc_sys_clk),
        .adc_reset_n           (adc_reset_n),
        .enable                (enable),
        .engine_enabled        (engine_enabled),
        .command_valid         (command_valid),
        .command_channel       (command_channel),
        .command_startofpacket (command_startofpacket),
        .command_endofpacket   (command_endofpacket),
        .command_ready         (command_ready),
        .response_valid        (response_valid),
        .response_channel      (response_channel),
        .response_data         (response_data),
        .response_startofpacket(response_startofpacket),
        .response_endofpacket  (response_endofpacket),
        .frame_valid           (frame_valid),
        .frame_ready           (frame_ready),
        .frame_seq             (frame_seq),
        .valid_mask            (valid_mask),
        .samples_flat          (samples_flat),
        .error_event           (error_event)
    );

    // DUT 2: Per-bit Toggle CDC
    adc_error_event_cdc u_cdc (
        .adc_sys_clk      (adc_sys_clk),
        .adc_reset_n      (adc_reset_n),
        .error_event      (error_event),
        .pclk             (pclk),
        .pclk_reset_n     (pclk_reset_n),
        .error_pulse_pclk (error_pulse_pclk)
    );

    // Source domain cycle and event tracking
    integer src_cycles = 0;
    integer src_count [0:3];
    integer prev_src_cycle [0:3];
    integer min_spacing_cycles [0:3];
    integer i;

    always @(posedge adc_sys_clk) begin
        if (adc_reset_n) begin
            src_cycles <= src_cycles + 1;
            for (i = 0; i < 4; i = i + 1) begin
                if (error_event[i]) begin
                    src_count[i] <= src_count[i] + 1;
                    if (prev_src_cycle[i] >= 0) begin
                        if ((src_cycles - prev_src_cycle[i]) < min_spacing_cycles[i]) begin
                            min_spacing_cycles[i] <= src_cycles - prev_src_cycle[i];
                        end
                    end
                    prev_src_cycle[i] <= src_cycles;
                end
            end
        end
    end

    // Destination domain pulse tracking
    integer dst_count [0:3];

    always @(posedge pclk) begin
        if (pclk_reset_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                if (error_pulse_pclk[i]) begin
                    dst_count[i] <= dst_count[i] + 1;
                end
            end
        end
    end

    task check(input condition, input [8*128-1:0] msg);
        begin
            if (!condition) begin
                $display("FAIL: %0s (time=%0t)", msg, $time);
                $fatal(1);
            end
        end
    endtask

    task wait_pclk_settle(input integer count);
        begin
            repeat (count) @(posedge pclk);
        end
    endtask

    // Responsive stimulus generator for fastest legal engine interaction
    reg       inject_active = 0;
    integer   inject_target = 0;
    integer   inject_count = 0;
    reg [4:0] inject_ch = 5'd3;
    reg       inject_sop = 1'b1;
    reg       inject_eop = 1'b1;
    reg       inject_duplicate_mode = 0;

    always @(posedge adc_sys_clk or negedge adc_reset_n) begin
        if (!adc_reset_n) begin
            response_valid         <= 1'b0;
            response_channel       <= 5'd0;
            response_data          <= 12'd0;
            response_startofpacket <= 1'b0;
            response_endofpacket   <= 1'b0;
            inject_count           <= 0;
        end else if (inject_active && (inject_count < inject_target)) begin
            if (!inject_duplicate_mode) begin
                // Fastest rate: as soon as command is accepted (command_valid && command_ready),
                // offer malformed response on the next cycle
                if (command_valid && command_ready) begin
                    response_valid         <= 1'b1;
                    response_channel       <= inject_ch;
                    response_data          <= 12'h123;
                    response_startofpacket <= inject_sop;
                    response_endofpacket   <= inject_eop;
                    inject_count           <= inject_count + 1;
                end else begin
                    response_valid         <= 1'b0;
                end
            end else begin
                // Duplicate mode: accept CH1 legally, then inject duplicate CH1 in WAIT_CH2
                if (command_valid && command_ready) begin
                    response_valid         <= 1'b1;
                    response_startofpacket <= 1'b1;
                    response_endofpacket   <= 1'b1;
                    if (command_channel == 5'd1) begin
                        response_channel   <= 5'd1; // Legal CH1
                        response_data      <= 12'h111;
                    end else begin
                        response_channel   <= 5'd1; // Malformed duplicate CH1 in CH2 stage
                        response_data      <= 12'h222;
                        inject_count       <= inject_count + 1;
                    end
                end else begin
                    response_valid         <= 1'b0;
                end
            end
        end else begin
            response_valid <= 1'b0;
        end
    end

    // Subtest task for a single error bit
    task test_bit(
        input integer bit_idx,
        input [4:0]   ch,
        input         sop,
        input         eop,
        input         dup_mode,
        input integer target,
        input integer expected_min_spacing,
        input [8*32-1:0] bit_name
    );
        begin
            $display("--- Testing %0s (Bit %0d) at maximum engine rate ---", bit_name, bit_idx);
            // Synchronous clean reset between subtests
            @(posedge adc_sys_clk);
            adc_reset_n  = 0;
            pclk_reset_n = 0;
            enable       = 0;
            inject_active = 0;
            for (i = 0; i < 4; i = i + 1) begin
                src_count[i] = 0;
                dst_count[i] = 0;
                prev_src_cycle[i] = -1;
                min_spacing_cycles[i] = 999999;
            end
            src_cycles = 0;
            repeat (2) @(posedge adc_sys_clk);
            adc_reset_n  = 1;
            @(posedge pclk);
            pclk_reset_n = 1;
            wait_pclk_settle(5);

            @(posedge adc_sys_clk);
            enable = 1;

            inject_ch = ch;
            inject_sop = sop;
            inject_eop = eop;
            inject_duplicate_mode = dup_mode;
            inject_target = target;
            inject_count = 0;
            inject_active = 1;

            while (src_count[bit_idx] < target) @(posedge adc_sys_clk);
            inject_active = 0;

            wait_pclk_settle(30);
            check(src_count[bit_idx] == target, "exact expected source error count produced");
            check(dst_count[bit_idx] == target, "CDC delivered exact matching pulse count to PCLK");
            check(min_spacing_cycles[bit_idx] == expected_min_spacing,
                  "measured engine minimum spacing matches expected spacing");
            $display("[PASS] %0s: sent=%0d, received=%0d, measured_min_spacing=%0d cycles",
                     bit_name, src_count[bit_idx], dst_count[bit_idx], min_spacing_cycles[bit_idx]);
        end
    endtask

    // Run test iteration for given clock configuration
    task run_engine_cdc_test(input [8*32-1:0] label, input real adc_p, input real pclk_p);
        begin
            $display("=== Running Engine+CDC Integration: %0s (ADC=%0.1fns, PCLK=%0.1fns) ===",
                     label, adc_p, pclk_p);

            adc_clk_period = adc_p;
            pclk_period = pclk_p;

            // Reset
            adc_reset_n   = 0;
            pclk_reset_n  = 0;
            enable        = 0;
            command_ready = 1;
            inject_active = 0;
            inject_target = 0;
            inject_count  = 0;
            inject_duplicate_mode = 0;
            for (i = 0; i < 4; i = i + 1) begin
                src_count[i] = 0;
                dst_count[i] = 0;
                prev_src_cycle[i] = -1;
                min_spacing_cycles[i] = 999999;
            end
            src_cycles = 0;

            wait_pclk_settle(5);
            @(posedge adc_sys_clk); adc_reset_n = 1;
            @(posedge pclk);        pclk_reset_n = 1;
            wait_pclk_settle(5);

            // 1. Bit 0: ERR_UNEXPECTED_CHANNEL (channel 3) -> minimum spacing = 2 cycles
            test_bit(0, 5'd3, 1'b1, 1'b1, 0, 10, 2, "UNEXPECTED_CHANNEL");

            // 2. Bit 2: ERR_ORDER_ERROR (channel 2 in CH1 stage) -> minimum spacing = 2 cycles
            test_bit(2, 5'd2, 1'b1, 1'b1, 0, 10, 2, "ORDER_ERROR");

            // 3. Bit 3: ERR_PACKET_ERROR (missing SOP) -> minimum spacing = 2 cycles
            test_bit(3, 5'd1, 1'b0, 1'b1, 0, 10, 2, "PACKET_ERROR");

            // 4. Bit 1: ERR_DUPLICATE_CHANNEL (CH1 twice) -> minimum spacing = 4 cycles (2 conversions)
            test_bit(1, 5'd1, 1'b1, 1'b1, 1, 10, 4, "DUPLICATE_CHANNEL");

            // Verify final totals for this configuration
            for (i = 0; i < 4; i = i + 1) begin
                check(src_count[i] == dst_count[i], "exact 1-to-1 transfer across all bits");
            end
            $display("SUCCESS: %0s passed with zero lost, zero duplicates.\n", label);
        end
    endtask

    initial begin
        $display("==========================================================");
        $display("Starting tb_adc_engine_cdc_integration");
        $display("Preferred Stronger Proof: Engine + Error CDC Closed-Loop");
        $display("==========================================================");

        // Case 1: Canonical 25 MHz adc_sys_clk -> 50 MHz PCLK (spec/15_adc_joystick.md)
        run_engine_cdc_test("Canonical 25MHz -> 50MHz", 40.0, 20.0);

        // Case 2: 10 MHz ADC hard-IP input clock -> 50 MHz PCLK
        run_engine_cdc_test("10MHz ADC -> 50MHz PCLK", 100.0, 20.0);

        // Case 3: 50 MHz adc_sys_clk -> 50 MHz PCLK (Synchronous maximum rate)
        run_engine_cdc_test("50MHz ADC -> 50MHz PCLK", 20.0, 20.0);

        // Case 4: Asynchronous / Incommensurate clock periods (17ns -> 23ns)
        run_engine_cdc_test("Incommensurate 17ns -> 23ns", 17.0, 23.0);

        $display("SUMMARY: PASS tb_adc_engine_cdc_integration");
        $finish;
    end

endmodule
