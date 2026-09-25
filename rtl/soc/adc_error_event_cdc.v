`timescale 1ns/1ps

// =============================================================================
// Module: adc_error_event_cdc
//
// Description:
//   Transfers four independent one-cycle error events from the adc_sys_clk domain
//   into one-cycle event pulses in the PCLK domain using per-bit toggle CDC.
//
// Invariants & Requirements:
//   - Each of the 4 error bits operates completely independently.
//   - Each source-domain pulse toggles a source toggle register.
//   - In the destination domain, a 2-stage synchronizer and an edge-detect
//     flop generate exactly one destination-domain pulse per toggle transition.
//   - Coincident events across different bits are transferred without interference.
//   - Supported same-bit minimum event separation is guaranteed by the acquisition
//     engine recovery cycle (minimum >= 2 adc_sys_clk cycles, typically >> conversion
//     time), preventing double-toggle aliasing.
// =============================================================================

module adc_error_event_cdc (
    input  wire       adc_sys_clk,
    input  wire       adc_reset_n,
    input  wire [3:0] error_event,

    input  wire       pclk,
    input  wire       pclk_reset_n,
    output wire [3:0] error_pulse_pclk
);

    // Source domain: per-bit toggle registers
    reg [3:0] error_toggle_q;
    integer i;

    always @(posedge adc_sys_clk or negedge adc_reset_n) begin
        if (!adc_reset_n) begin
            error_toggle_q <= 4'b0000;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                if (error_event[i]) begin
                    error_toggle_q[i] <= ~error_toggle_q[i];
                end
            end
        end
    end

    // Destination domain: 2-FF synchronizer + 1 delay stage for edge detection
    reg [3:0] toggle_sync1;
    reg [3:0] toggle_sync2;
    reg [3:0] toggle_delayed;

    always @(posedge pclk or negedge pclk_reset_n) begin
        if (!pclk_reset_n) begin
            toggle_sync1   <= 4'b0000;
            toggle_sync2   <= 4'b0000;
            toggle_delayed <= 4'b0000;
        end else begin
            toggle_sync1   <= error_toggle_q;
            toggle_sync2   <= toggle_sync1;
            toggle_delayed <= toggle_sync2;
        end
    end

    assign error_pulse_pclk = toggle_sync2 ^ toggle_delayed;

endmodule
