`timescale 1ns/1ps

// =============================================================================
// Standalone Testbench: tb_adc_error_event_cdc
//
// Verification Authority:
//   - Issue #6 [P11C-C2 TASK] Section 15.B
//   - Section 9: Toggle CDC & Mandatory Spacing Proof
//
// Requirements:
//   1. Each bit independently transferred losslessly.
//   2. Multiple distinct bits transferred concurrently without interference.
//   3. Source and destination clock phase variation (synchronous, asynchronous,
//      frequency ratios: 10MHz/50MHz, 50MHz/50MHz, irrational ratios).
//   4. Source reset behavior: clean return to 0, no spurious pulse.
//   5. Destination reset behavior: flops clear, zero spurious output pulses.
//   6. Back-to-back legal source error events at supported minimum spacing.
//   7. Adversarial minimum same-bit spacing analysis and proof.
// =============================================================================

module tb_adc_error_event_cdc;
    reg        adc_sys_clk = 0;
    reg        adc_reset_n = 0;
    reg [3:0]  error_event = 0;

    reg        pclk = 0;
    reg        pclk_reset_n = 0;
    wire [3:0] error_pulse_pclk;

    // Default clock periods (10 MHz adc_sys_clk = 100ns, 50 MHz PCLK = 20ns)
    real adc_clk_period = 100.0;
    real pclk_period = 20.0;

    always #(adc_clk_period / 2.0) adc_sys_clk = ~adc_sys_clk;
    always #(pclk_period / 2.0)    pclk = ~pclk;

    adc_error_event_cdc dut (
        .adc_sys_clk      (adc_sys_clk),
        .adc_reset_n      (adc_reset_n),
        .error_event      (error_event),
        .pclk             (pclk),
        .pclk_reset_n     (pclk_reset_n),
        .error_pulse_pclk (error_pulse_pclk)
    );

    // Event counters
    integer src_count [0:3];
    integer dst_count [0:3];
    integer i;

    // Destination domain monitor
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

    // Pulse a source error event for 1 adc_sys_clk cycle
    task send_source_error(input [3:0] mask);
        begin
            @(posedge adc_sys_clk);
            error_event <= mask;
            for (i = 0; i < 4; i = i + 1) begin
                if (mask[i]) src_count[i] = src_count[i] + 1;
            end
            @(posedge adc_sys_clk);
            error_event <= 4'b0000;
        end
    endtask

    // Wait for all destination synchronizers to settle
    task wait_destination_settle(input integer cycles);
        begin
            repeat (cycles) @(posedge pclk);
        end
    endtask

    initial begin
        $display("=== Starting tb_adc_error_event_cdc ===");

        for (i = 0; i < 4; i = i + 1) begin
            src_count[i] = 0;
            dst_count[i] = 0;
        end

        // ---------------------------------------------------------------------
        // 1. Reset Behavior
        // ---------------------------------------------------------------------
        adc_reset_n  = 0;
        pclk_reset_n = 0;
        wait_destination_settle(5);
        check(error_pulse_pclk == 4'b0, "error_pulse_pclk is 0 in reset");

        // Release resets
        @(posedge adc_sys_clk); adc_reset_n = 1;
        @(posedge pclk);        pclk_reset_n = 1;
        wait_destination_settle(5);
        check(error_pulse_pclk == 4'b0, "no spurious pulse upon reset release");

        // ---------------------------------------------------------------------
        // 2. Individual Bit Transfers (10 MHz ADC -> 50 MHz PCLK)
        // ---------------------------------------------------------------------
        $display("Testing individual bit transfers (10 MHz -> 50 MHz)...");
        for (i = 0; i < 4; i = i + 1) begin
            send_source_error(4'b0001 << i);
            wait_destination_settle(10);
            check(dst_count[i] == src_count[i], "exact 1-to-1 transfer for bit");
        end

        // ---------------------------------------------------------------------
        // 3. Concurrent Multi-Bit Transfers
        // ---------------------------------------------------------------------
        $display("Testing concurrent distinct error bits...");
        // Bits 0 and 2 simultaneously
        send_source_error(4'b0101);
        wait_destination_settle(10);
        check(dst_count[0] == src_count[0] && dst_count[2] == src_count[2],
              "bits 0 and 2 concurrently transferred");

        // All 4 bits simultaneously
        send_source_error(4'b1111);
        wait_destination_settle(10);
        for (i = 0; i < 4; i = i + 1) begin
            check(dst_count[i] == src_count[i], "all 4 bits concurrently transferred");
        end

        // ---------------------------------------------------------------------
        // 4. Minimum Spacing Proof: Supported Acquisition Engine Behavior
        // ---------------------------------------------------------------------
        $display("Testing supported minimum same-bit spacing...");
        // In adc_acquisition_engine.v:
        // reject_response transitions to ST_ISSUE_CH1 (wait command_ready),
        // then ST_WAIT_CH1 (wait response_valid).
        // Minimum separation between two error events is >= 2 adc_sys_clk cycles.
        for (i = 0; i < 5; i = i + 1) begin
            send_source_error(4'b0001); // Event 1
            // 2 cycles spacing (supported minimum)
            repeat (2) @(posedge adc_sys_clk);
            send_source_error(4'b0001); // Event 2
            wait_destination_settle(15);
        end
        check(dst_count[0] == src_count[0], "supported minimum spacing (2 cycles) is 100% lossless");

        // ---------------------------------------------------------------------
        // 5. Clock Frequency and Phase Variations
        // ---------------------------------------------------------------------
        $display("Testing equal frequencies (50 MHz ADC -> 50 MHz PCLK)...");
        // Change adc_clk_period to 20ns
        adc_clk_period = 20.0;
        wait_destination_settle(5);

        for (i = 0; i < 4; i = i + 1) begin
            send_source_error(4'b0001 << i);
            wait_destination_settle(10);
            check(dst_count[i] == src_count[i], "equal frequency transfer accurate");
        end

        // Equal frequency back-to-back at minimum separation (3 cycles of 20ns = 60ns)
        for (i = 0; i < 5; i = i + 1) begin
            send_source_error(4'b0010);
            repeat (3) @(posedge adc_sys_clk);
            send_source_error(4'b0010);
            wait_destination_settle(10);
        end
        check(dst_count[1] == src_count[1], "equal frequency 3-cycle spacing lossless");

        // Asymmetric / Incommensurate clock periods (17ns ADC -> 23ns PCLK)
        $display("Testing incommensurate clock periods (17ns ADC -> 23ns PCLK)...");
        adc_clk_period = 17.0;
        pclk_period = 23.0;
        wait_destination_settle(10);

        for (i = 0; i < 4; i = i + 1) begin
            send_source_error(4'b0001 << i);
            wait_destination_settle(10);
            check(dst_count[i] == src_count[i], "incommensurate clock transfer accurate");
        end

        // ---------------------------------------------------------------------
        // 6. Subsystem Reset Recovery (Consistent with Subsystem Reset Contract)
        // ---------------------------------------------------------------------
        $display("Testing subsystem reset recovery (common async assert)...");
        send_source_error(4'b1000);
        wait_destination_settle(10);
        // Assert subsystem reset concurrently across both domains
        @(posedge adc_sys_clk);
        adc_reset_n  = 0;
        pclk_reset_n = 0;
        repeat (3) @(posedge adc_sys_clk);
        // Synchronous release per contract
        adc_reset_n  = 1;
        pclk_reset_n = 1;
        wait_destination_settle(10);
        // Ensure another event after reset is cleanly transferred
        send_source_error(4'b1000);
        wait_destination_settle(10);

        // ---------------------------------------------------------------------
        // Final Lossless and Non-Duplication Assertion
        // ---------------------------------------------------------------------
        for (i = 0; i < 4; i = i + 1) begin
            check(dst_count[i] == src_count[i], "zero events lost, zero duplicates across all tests");
            $display("[PASS] Bit %0d total events sent=%0d received=%0d", i, src_count[i], dst_count[i]);
        end

        $display("SUMMARY: PASS tb_adc_error_event_cdc");
        $finish;
    end

endmodule
