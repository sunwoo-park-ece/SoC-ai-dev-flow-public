`timescale 1ns/1ps

// =============================================================================
// Testbench: tb_joystick_policy
//
// Directed & Random Verification for combinational Joystick_Policy.
// Covers:
//   - Combinational zero-latency / reset-independent response
//   - Strict inequalities (exact threshold equality -> neutral)
//   - ±1 count above/below threshold boundary assertions
//   - Independent X and Y valid-mask gating
//   - Center near 0 with deadzone underflow clamp
//   - Center near 4095 with deadzone overflow clamp
//   - Deadzone = 0 and Deadzone = 4095 boundary checks
//   - Live calibration update without new sample
//   - All individual directions and all 4 diagonal quadrants
//   - Full 6-bit JOY_STATUS packing alignment
//   - Randomized vector stress against independent golden mathematical oracle
// =============================================================================

module tb_joystick_policy;

    reg  [11:0] hold_ch1;
    reg  [11:0] hold_ch2;
    reg  [5:0]  hold_valid_mask;
    reg  [11:0] center_x;
    reg  [11:0] center_y;
    reg  [11:0] deadzone;
    wire [5:0]  joy_status;

    // DUT instantiation
    Joystick_Policy dut (
        .hold_ch1        (hold_ch1),
        .hold_ch2        (hold_ch2),
        .hold_valid_mask (hold_valid_mask),
        .center_x        (center_x),
        .center_y        (center_y),
        .deadzone        (deadzone),
        .joy_status      (joy_status)
    );

    integer error_count = 0;
    integer corpus_file = 0;
    integer corpus_count = 0;
    integer vec_x, vec_y, vec_mask, vec_cx, vec_cy, vec_dz, vec_expected;

    // Independent Golden Mathematical Model (Specification Section 4)
    function [5:0] golden_model(
        input [11:0] x,
        input [11:0] y,
        input [5:0]  mask,
        input [11:0] cx,
        input [11:0] cy,
        input [11:0] dz
    );
        reg x_v, y_v;
        integer sum_hx, sub_lx, sum_hy, sub_ly;
        integer h_x, l_x, h_y, l_y;
        reg rgt, lft, fwd, bwd;
        begin
            x_v = mask[0];
            y_v = mask[1];

            sum_hx = cx + dz;
            h_x = (sum_hx > 4095) ? 4095 : sum_hx;

            sub_lx = cx - dz;
            l_x = (sub_lx < 0) ? 0 : sub_lx;

            sum_hy = cy + dz;
            h_y = (sum_hy > 4095) ? 4095 : sum_hy;

            sub_ly = cy - dz;
            l_y = (sub_ly < 0) ? 0 : sub_ly;

            rgt = x_v && (x > h_x);
            lft = x_v && (x < l_x);
            fwd = y_v && (y > h_y);
            bwd = y_v && (y < l_y);

            golden_model = {y_v, x_v, rgt, lft, bwd, fwd};
        end
    endfunction

    task check_case(input string label);
        reg [5:0] expected;
        begin
            #1; // propagate combinational logic
            expected = golden_model(hold_ch1, hold_ch2, hold_valid_mask, center_x, center_y, deadzone);
            if (joy_status !== expected) begin
                $display("[FAIL] %s: inputs X=%0d Y=%0d M=%b CX=%0d CY=%0d DZ=%0d | expected %b, got %b",
                         label, hold_ch1, hold_ch2, hold_valid_mask, center_x, center_y, deadzone,
                         expected, joy_status);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        $display("=== Starting tb_joystick_policy ===");

        // Default calibration: Center=2048, Deadzone=300
        center_x = 12'd2048;
        center_y = 12'd2048;
        deadzone = 12'd300;
        hold_valid_mask = 6'b000011; // both X and Y valid

        // ---------------------------------------------------------------------
        // 1. Center / Neutral state
        // ---------------------------------------------------------------------
        hold_ch1 = 12'd2048;
        hold_ch2 = 12'd2048;
        check_case("Default Center Neutral");
        if (joy_status !== 6'b110000) begin
            $display("[FAIL] Expected joy_status == 6'b110000 (X_VALID=1, Y_VALID=1, neutral)");
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 2. Exact Threshold Equality -> Neutral (Strict Inequality)
        // High threshold = 2048 + 300 = 2348
        // Low threshold  = 2048 - 300 = 1748
        // ---------------------------------------------------------------------
        // Exact high equality
        hold_ch1 = 12'd2348;
        hold_ch2 = 12'd2348;
        check_case("Exact High Threshold Equality");
        if (joy_status[3:0] !== 4'b0000) begin
            $display("[FAIL] Exact high threshold equality did not yield neutral direction");
            error_count = error_count + 1;
        end

        // Exact low equality
        hold_ch1 = 12'd1748;
        hold_ch2 = 12'd1748;
        check_case("Exact Low Threshold Equality");
        if (joy_status[3:0] !== 4'b0000) begin
            $display("[FAIL] Exact low threshold equality did not yield neutral direction");
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 3. Boundary ±1 Count Transitions
        // ---------------------------------------------------------------------
        // RIGHT boundary: 2348 is neutral, 2349 is RIGHT
        hold_ch1 = 12'd2349;
        hold_ch2 = 12'd2048;
        check_case("Boundary Right +1");
        if (joy_status[3] !== 1'b1 || joy_status[2:0] !== 3'b000) begin
            $display("[FAIL] RIGHT asserted incorrectly at 2349");
            error_count = error_count + 1;
        end

        // LEFT boundary: 1748 is neutral, 1747 is LEFT
        hold_ch1 = 12'd1747;
        hold_ch2 = 12'd2048;
        check_case("Boundary Left -1");
        if (joy_status[2] !== 1'b1 || {joy_status[3], joy_status[1:0]} !== 3'b000) begin
            $display("[FAIL] LEFT asserted incorrectly at 1747");
            error_count = error_count + 1;
        end

        // FORWARD boundary: 2348 is neutral, 2349 is FORWARD
        hold_ch1 = 12'd2048;
        hold_ch2 = 12'd2349;
        check_case("Boundary Forward +1");
        if (joy_status[0] !== 1'b1 || joy_status[3:1] !== 3'b000) begin
            $display("[FAIL] FORWARD asserted incorrectly at 2349");
            error_count = error_count + 1;
        end

        // BACKWARD boundary: 1748 is neutral, 1747 is BACKWARD
        hold_ch1 = 12'd2048;
        hold_ch2 = 12'd1747;
        check_case("Boundary Backward -1");
        if (joy_status[1] !== 1'b1 || {joy_status[3:2], joy_status[0]} !== 3'b000) begin
            $display("[FAIL] BACKWARD asserted incorrectly at 1747");
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 4. Diagonal Quadrants
        // ---------------------------------------------------------------------
        // FORWARD + RIGHT
        hold_ch1 = 12'd2500;
        hold_ch2 = 12'd2500;
        check_case("Diagonal FORWARD + RIGHT");
        if (joy_status !== 6'b111001) begin
            $display("[FAIL] FORWARD+RIGHT failed: got %b, expected 6'b111001", joy_status);
            error_count = error_count + 1;
        end

        // FORWARD + LEFT
        hold_ch1 = 12'd1500;
        hold_ch2 = 12'd2500;
        check_case("Diagonal FORWARD + LEFT");
        if (joy_status !== 6'b110101) begin
            $display("[FAIL] FORWARD+LEFT failed: got %b, expected 6'b110101", joy_status);
            error_count = error_count + 1;
        end

        // BACKWARD + RIGHT
        hold_ch1 = 12'd2500;
        hold_ch2 = 12'd1500;
        check_case("Diagonal BACKWARD + RIGHT");
        if (joy_status !== 6'b111010) begin
            $display("[FAIL] BACKWARD+RIGHT failed: got %b, expected 6'b111010", joy_status);
            error_count = error_count + 1;
        end

        // BACKWARD + LEFT
        hold_ch1 = 12'd1500;
        hold_ch2 = 12'd1500;
        check_case("Diagonal BACKWARD + LEFT");
        if (joy_status !== 6'b110110) begin
            $display("[FAIL] BACKWARD+LEFT failed: got %b, expected 6'b110110", joy_status);
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 5. Valid-mask Gating & Isolation
        // ---------------------------------------------------------------------
        // Mask = 0: All directions gated to 0, valid bits = 0
        hold_valid_mask = 6'b000000;
        hold_ch1 = 12'd4095;
        hold_ch2 = 12'd4095;
        check_case("Mask=0 Gating All");
        if (joy_status !== 6'b000000) begin
            $display("[FAIL] Mask=0 did not gate all outputs: got %b", joy_status);
            error_count = error_count + 1;
        end

        // Mask = 1 (X only valid): X directions pass, Y directions gated
        hold_valid_mask = 6'b000001;
        hold_ch1 = 12'd2500; // RIGHT
        hold_ch2 = 12'd2500; // FORWARD should be gated
        check_case("Mask=1 X Valid Only");
        if (joy_status !== 6'b011000) begin
            $display("[FAIL] Mask=1 (X valid only) failed: got %b, expected 6'b011000", joy_status);
            error_count = error_count + 1;
        end

        // Mask = 2 (Y only valid): Y directions pass, X directions gated
        hold_valid_mask = 6'b000010;
        hold_ch1 = 12'd2500; // RIGHT should be gated
        hold_ch2 = 12'd2500; // FORWARD
        check_case("Mask=2 Y Valid Only");
        if (joy_status !== 6'b100001) begin
            $display("[FAIL] Mask=2 (Y valid only) failed: got %b, expected 6'b100001", joy_status);
            error_count = error_count + 1;
        end

        // Upper bits of mask (e.g. 6'b111111) do not corrupt bits 0..5
        hold_valid_mask = 6'b111111;
        check_case("Mask=6'b111111 Upper Bits Ignored");
        if (joy_status !== 6'b111001) begin
            $display("[FAIL] Upper mask bits corrupted evaluation: got %b", joy_status);
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 6. Saturation / Underflow / Overflow Clamping
        // ---------------------------------------------------------------------
        // Center near 0: center_x=100, deadzone=200 -> low_x clamps to 0
        hold_valid_mask = 6'b000011;
        center_x = 12'd100;
        deadzone = 12'd200;
        // At low_x clamp = 0, no 12-bit unsigned value can be < 0 -> LEFT never asserts
        hold_ch1 = 12'd0;
        hold_ch2 = 12'd2048;
        center_y = 12'd2048;
        check_case("Underflow Clamp Low=0 Left Test");
        if (joy_status[2] !== 1'b0) begin
            $display("[FAIL] Underflow clamp failed: LEFT asserted at x=0 when low_x=0");
            error_count = error_count + 1;
        end
        // High threshold = 100 + 200 = 300. Test RIGHT at 301
        hold_ch1 = 12'd301;
        check_case("Underflow Clamp High=300 Right Test");
        if (joy_status[3] !== 1'b1) begin
            $display("[FAIL] RIGHT failed to assert at 301 when high_x=300");
            error_count = error_count + 1;
        end

        // Center near 4095: center_y=4000, deadzone=200 -> high_y clamps to 4095
        center_y = 12'd4000;
        deadzone = 12'd200;
        // At high_y clamp = 4095, no 12-bit unsigned value can be > 4095 -> FORWARD never asserts
        hold_ch1 = 12'd2048;
        center_x = 12'd2048;
        hold_ch2 = 12'd4095;
        check_case("Overflow Clamp High=4095 Forward Test");
        if (joy_status[0] !== 1'b0) begin
            $display("[FAIL] Overflow clamp failed: FORWARD asserted at y=4095 when high_y=4095");
            error_count = error_count + 1;
        end
        // Low threshold = 4000 - 200 = 3800. Test BACKWARD at 3799
        hold_ch2 = 12'd3799;
        check_case("Overflow Clamp Low=3800 Backward Test");
        if (joy_status[1] !== 1'b1) begin
            $display("[FAIL] BACKWARD failed to assert at 3799 when low_y=3800");
            error_count = error_count + 1;
        end

        // Deadzone = 0
        center_x = 12'd2048;
        center_y = 12'd2048;
        deadzone = 12'd0;
        hold_ch1 = 12'd2048;
        hold_ch2 = 12'd2048;
        check_case("Deadzone=0 Neutral at Center");
        if (joy_status !== 6'b110000) begin
            $display("[FAIL] Deadzone=0 at center failed: got %b", joy_status);
            error_count = error_count + 1;
        end
        hold_ch1 = 12'd2049;
        check_case("Deadzone=0 Right at 2049");
        if (joy_status[3] !== 1'b1) begin
            $display("[FAIL] Deadzone=0 RIGHT failed at 2049");
            error_count = error_count + 1;
        end
        hold_ch1 = 12'd2047;
        check_case("Deadzone=0 Left at 2047");
        if (joy_status[2] !== 1'b1) begin
            $display("[FAIL] Deadzone=0 LEFT failed at 2047");
            error_count = error_count + 1;
        end

        // Deadzone = 4095 (All directions must be neutral everywhere)
        deadzone = 12'd4095;
        hold_ch1 = 12'd0;
        hold_ch2 = 12'd4095;
        check_case("Deadzone=4095 Extremes Neutral");
        if (joy_status[3:0] !== 4'b0000) begin
            $display("[FAIL] Deadzone=4095 failed to keep directions neutral");
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 7. Live Calibration Update (No Sample Change)
        // ---------------------------------------------------------------------
        hold_ch1 = 12'd2200;
        hold_ch2 = 12'd2200;
        deadzone = 12'd300; // high = 2348 -> neutral
        check_case("Live Cal: Initial Neutral");
        if (joy_status[3:0] !== 4'b0000) begin
            $display("[FAIL] Live Cal initial state not neutral");
            error_count = error_count + 1;
        end

        // Change deadzone to 100 without touching hold_ch1/ch2 -> high = 2148 -> FORWARD + RIGHT
        deadzone = 12'd100;
        check_case("Live Cal: Narrow Deadzone -> Immediate Trigger");
        if (joy_status !== 6'b111001) begin
            $display("[FAIL] Live Cal deadzone change failed to update immediately: got %b", joy_status);
            error_count = error_count + 1;
        end

        // Change center_x to 2250 -> high_x = 2350, low_x = 2150 -> X becomes neutral again
        center_x = 12'd2250;
        check_case("Live Cal: Center Shift -> Immediate Neutral");
        if (joy_status !== 6'b110001) begin
            $display("[FAIL] Live Cal center_x shift failed to update immediately: got %b", joy_status);
            error_count = error_count + 1;
        end

        // ---------------------------------------------------------------------
        // 8. Randomized Stress Vectors (10,000 vectors)
        // ---------------------------------------------------------------------
        $display("Running 10,000 randomized stress vectors...");
        for (integer i = 0; i < 10000; i = i + 1) begin
            hold_ch1 = $urandom_range(0, 4095);
            hold_ch2 = $urandom_range(0, 4095);
            hold_valid_mask = $urandom_range(0, 63);
            center_x = $urandom_range(0, 4095);
            center_y = $urandom_range(0, 4095);
            deadzone = $urandom_range(0, 4095);
            #1;
            if (joy_status !== golden_model(hold_ch1, hold_ch2, hold_valid_mask, center_x, center_y, deadzone)) begin
                $display("[FAIL] Random vector %0d mismatch: X=%0d Y=%0d M=%b CX=%0d CY=%0d DZ=%0d | DUT=%b Oracle=%b",
                         i, hold_ch1, hold_ch2, hold_valid_mask, center_x, center_y, deadzone,
                         joy_status, golden_model(hold_ch1, hold_ch2, hold_valid_mask, center_x, center_y, deadzone));
                error_count = error_count + 1;
                if (error_count > 20) $fatal(1, "Too many random vector failures");
            end
        end

        // ---------------------------------------------------------------------
        // 9. Shared Test Vector Corpus Cross-Check (policy_vectors.txt)
        // ---------------------------------------------------------------------
        $display("Verifying shared test vector corpus (policy_vectors.txt)...");
        corpus_file = $fopen("verification/directed/adc/policy_vectors.txt", "r");
        if (corpus_file != 0) begin
            corpus_count = 0;
            while ($fscanf(corpus_file, "%d %d %d %d %d %d %d\n",
                           vec_x, vec_y, vec_mask, vec_cx, vec_cy, vec_dz, vec_expected) == 7) begin
                hold_ch1 = vec_x[11:0];
                hold_ch2 = vec_y[11:0];
                hold_valid_mask = vec_mask[5:0];
                center_x = vec_cx[11:0];
                center_y = vec_cy[11:0];
                deadzone = vec_dz[11:0];
                #1;
                if (joy_status !== vec_expected[5:0]) begin
                    $display("[FAIL] Corpus vector %0d mismatch: expected %b, got %b",
                             corpus_count, vec_expected[5:0], joy_status);
                    error_count = error_count + 1;
                end
                corpus_count = corpus_count + 1;
            end
            $fclose(corpus_file);
            $display("[PASS] Shared test vector corpus verified: %0d vectors", corpus_count);
        end else begin
            $display("[FAIL] Could not open verification/directed/adc/policy_vectors.txt");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("SUMMARY: PASS tb_joystick_policy (directed, random, and shared corpus passed)");
            $display("PASS tb_joystick_policy");
        end else begin
            $display("SUMMARY: FAIL tb_joystick_policy with %0d errors", error_count);
            $fatal(1);
        end
        $finish;
    end

endmodule
