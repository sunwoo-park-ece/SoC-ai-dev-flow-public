`timescale 1ns/1ps

// =============================================================================
// Module: Joystick_Policy
//
// Description:
//   Pure combinational hardware policy evaluating digital joystick direction
//   states and axis validities from a coherent ADC HOLD snapshot frame and
//   current calibration registers.
//
// Architecture & Verification Authority:
//   - Issue #6 [P11C-C3 TASK] Sections 3 & 4
//   - spec/15_adc_joystick.md Section 4
//
// Boundary & Invariants:
//   - Purely combinational logic (zero clock, zero reset, zero internal state).
//   - Contains no APB decode, no CDC, no command scheduling, no buffer logic.
//   - Baseline logical channel mapping: CH1 -> X, CH2 -> Y.
//   - Uses widened arithmetic to clamp thresholds to [0, 4095] without overflow.
//   - Strict inequalities: exact threshold equality evaluates to neutral (0).
//   - Invalid axes strictly gate directions to 0.
//
// Output bit packing:
//   joy_status[0] = FORWARD
//   joy_status[1] = BACKWARD
//   joy_status[2] = LEFT
//   joy_status[3] = RIGHT
//   joy_status[4] = X_VALID
//   joy_status[5] = Y_VALID
// =============================================================================

module Joystick_Policy (
    input  wire [11:0] hold_ch1,        // logical X raw
    input  wire [11:0] hold_ch2,        // logical Y raw
    input  wire [5:0]  hold_valid_mask, // [0]: X valid, [1]: Y valid
    input  wire [11:0] center_x,
    input  wire [11:0] center_y,
    input  wire [11:0] deadzone,
    output wire [5:0]  joy_status
);

    // 1. Validity gating from HOLD frame
    wire x_valid = hold_valid_mask[0];
    wire y_valid = hold_valid_mask[1];
    wire unused_ok = &{1'b0, hold_valid_mask[5:2], 1'b0};

    // 2. Saturated 12-bit threshold calculations with widened arithmetic
    wire [12:0] sum_x = {1'b0, center_x} + {1'b0, deadzone};
    wire [11:0] high_x = (sum_x > 13'd4095) ? 12'd4095 : sum_x[11:0];
    wire [11:0] low_x  = (center_x > deadzone) ? (center_x - deadzone) : 12'd0;

    wire [12:0] sum_y = {1'b0, center_y} + {1'b0, deadzone};
    wire [11:0] high_y = (sum_y > 13'd4095) ? 12'd4095 : sum_y[11:0];
    wire [11:0] low_y  = (center_y > deadzone) ? (center_y - deadzone) : 12'd0;

    // 3. Direction evaluations (strict inequalities, exact equality is neutral)
    wire right    = x_valid && (hold_ch1 > high_x);
    wire left     = x_valid && (hold_ch1 < low_x);
    wire forward  = y_valid && (hold_ch2 > high_y);
    wire backward = y_valid && (hold_ch2 < low_y);

    // 4. Output bit packing
    assign joy_status = {
        y_valid,    // bit 5
        x_valid,    // bit 4
        right,      // bit 3
        left,       // bit 2
        backward,   // bit 1
        forward     // bit 0
    };

endmodule
