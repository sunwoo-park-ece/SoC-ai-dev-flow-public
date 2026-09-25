`timescale 1ns/1ps

// =============================================================================
// Module: APB_ADC_Controller
//
// Description:
//   Generic ADC MMIO v2.0 APB peripheral providing coherent software-visible
//   LIVE and HOLD snapshot banks, atomic capture, frame tracking, sticky error
//   reporting, and joystick calibration storage.
//
// Architecture & Verification Authority:
//   - Issue #6 [P11C-C2 TASK], spec/15_adc_joystick.md, spec/05_apb_subsystem.md,
//     spec/01_memory_map.md, spec/06_reset_clock.md, spec/baseline_cleanup.md
//   - C1 Acceptance Decision: ADC_STATUS[6] = 0 (ASSEMBLY_ACTIVE removed).
//
// Base Address: 0x4005_0000 (Slot 5)
// =============================================================================

module APB_ADC_Controller (
    input  wire        PCLK,
    input  wire        PRESETn,
    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERR,

    // P11B Mailbox publication & control boundary (PCLK domain)
    output wire        adc_enable_req,
    input  wire        engine_enabled_pclk,
    input  wire        frame_pulse_pclk,
    input  wire [31:0] frame_seq_pclk,
    input  wire [5:0]  valid_mask_pclk,
    input  wire [71:0] samples_flat_pclk,
    input  wire        mailbox_busy,

    // Error event pulses from CDC (PCLK domain)
    input  wire [3:0]  error_pulse_pclk,

    // C3 boundary for Joystick policy input (tied to 0 in C2)
    input  wire [5:0]  joy_status_i,
    output wire [11:0] joy_center_x_o,
    output wire [11:0] joy_center_y_o,
    output wire [11:0] joy_deadzone_o
);

    assign PREADY = 1'b1;

    // -------------------------------------------------------------------------
    // Canonical Address Decode & Access Legality
    // -------------------------------------------------------------------------
    wire [15:0] off = PADDR[15:0];

    wire is_canonical_offset = ((off <= 16'h004C) && (off[1:0] == 2'b00)) ||
                               (off == 16'h0060) ||
                               (off == 16'h0064);

    wire is_canonical_addr = ((PADDR[31:16] == 16'h4005) || (PADDR[31:16] == 16'h0000)) &&
                             is_canonical_offset;

    wire is_writable_offset = (off == 16'h000C) || // ADC_CTRL
                              (off == 16'h0040) || // JOY_CENTER_X
                              (off == 16'h0044) || // JOY_CENTER_Y
                              (off == 16'h0048);   // JOY_DEADZONE

    // ADC_CTRL write is malformed if any reserved bit [31:3] is non-zero
    wire malformed_ctrl_write = (off == 16'h000C) && (PWDATA[31:3] != 29'd0);

    wire legal_access = is_canonical_addr &&
                        (!PWRITE || (is_writable_offset && !malformed_ctrl_write));

    wire apb_access = PRESETn && PSEL && PENABLE;
    assign PSLVERR  = apb_access && !legal_access;

    wire valid_write = apb_access && PWRITE && legal_access;
    wire capture_req     = valid_write && (off == 16'h000C) && PWDATA[1];
    wire clear_error_req = valid_write && (off == 16'h000C) && PWDATA[2];

    // -------------------------------------------------------------------------
    // Persistent Registers & Control
    // -------------------------------------------------------------------------
    reg        enable_reg;
    reg [11:0] joy_center_x;
    reg [11:0] joy_center_y;
    reg [11:0] joy_deadzone;

    assign adc_enable_req = enable_reg;
    assign joy_center_x_o = joy_center_x;
    assign joy_center_y_o = joy_center_y;
    assign joy_deadzone_o = joy_deadzone;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            enable_reg   <= 1'b0;
            joy_center_x <= 12'd2048;
            joy_center_y <= 12'd2048;
            joy_deadzone <= 12'd300;
        end else if (valid_write) begin
            case (off)
                16'h000C: enable_reg   <= PWDATA[0];
                16'h0040: joy_center_x <= PWDATA[11:0];
                16'h0044: joy_center_y <= PWDATA[11:0];
                16'h0048: joy_deadzone <= PWDATA[11:0];
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // LIVE Bank & Disable Invalidation
    // -------------------------------------------------------------------------
    reg        live_valid;
    reg [31:0] live_seq;
    reg [5:0]  live_mask;
    reg [11:0] live_ch1, live_ch2, live_ch3, live_ch4, live_ch5, live_ch6;

    wire disabled_ack = (!enable_reg) && (!engine_enabled_pclk);

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            live_valid <= 1'b0;
            live_seq   <= 32'd0;
            live_mask  <= 6'd0;
            live_ch1   <= 12'd0;
            live_ch2   <= 12'd0;
            live_ch3   <= 12'd0;
            live_ch4   <= 12'd0;
            live_ch5   <= 12'd0;
            live_ch6   <= 12'd0;
        end else begin
            // Disabled acknowledgement invalidates LIVE eligibility
            if (disabled_ack) begin
                live_valid <= 1'b0;
            end else if (frame_pulse_pclk) begin
                live_valid <= 1'b1;
                live_seq   <= frame_seq_pclk;
                live_mask  <= valid_mask_pclk;
                live_ch1   <= samples_flat_pclk[11:0];
                live_ch2   <= samples_flat_pclk[23:12];
                live_ch3   <= samples_flat_pclk[35:24];
                live_ch4   <= samples_flat_pclk[47:36];
                live_ch5   <= samples_flat_pclk[59:48];
                live_ch6   <= samples_flat_pclk[71:60];
            end
        end
    end

    // -------------------------------------------------------------------------
    // HOLD Bank & Atomic CAPTURE
    // -------------------------------------------------------------------------
    reg        hold_valid;
    reg [31:0] hold_seq;
    reg [5:0]  hold_mask;
    reg [11:0] hold_ch1, hold_ch2, hold_ch3, hold_ch4, hold_ch5, hold_ch6;

    wire new_frame = live_valid && (!hold_valid || (live_seq != hold_seq));

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            hold_valid <= 1'b0;
            hold_seq   <= 32'd0;
            hold_mask  <= 6'd0;
            hold_ch1   <= 12'd0;
            hold_ch2   <= 12'd0;
            hold_ch3   <= 12'd0;
            hold_ch4   <= 12'd0;
            hold_ch5   <= 12'd0;
            hold_ch6   <= 12'd0;
        end else begin
            // Atomically copy entire LIVE generation if NEW_FRAME=1
            // If NEW_FRAME=0, CAPTURE is a clean no-op
            if (capture_req && new_frame) begin
                hold_valid <= 1'b1;
                hold_seq   <= live_seq;
                hold_mask  <= live_mask;
                hold_ch1   <= live_ch1;
                hold_ch2   <= live_ch2;
                hold_ch3   <= live_ch3;
                hold_ch4   <= live_ch4;
                hold_ch5   <= live_ch5;
                hold_ch6   <= live_ch6;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FRAME_COUNT
    // -------------------------------------------------------------------------
    reg [31:0] frame_count_reg;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            frame_count_reg <= 32'd0;
        end else if (frame_pulse_pclk) begin
            frame_count_reg <= frame_count_reg + 32'd1;
        end
    end

    // -------------------------------------------------------------------------
    // ERROR_STATUS & CLEAR_ERROR (Set-Dominant)
    // -------------------------------------------------------------------------
    reg [3:0] error_status_reg;
    integer k;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            error_status_reg <= 4'd0;
        end else begin
            for (k = 0; k < 4; k = k + 1) begin
                if (error_pulse_pclk[k]) begin
                    error_status_reg[k] <= 1'b1; // new error set wins over clear
                end else if (clear_error_req) begin
                    error_status_reg[k] <= 1'b0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // ADC_STATUS Assembly
    // -------------------------------------------------------------------------
    wire [31:0] adc_status_val = {
        24'd0,                        // [31:8] RESERVED = 0
        (|error_status_reg[3:0]),     // [7] ERROR_PENDING
        1'b0,                         // [6] RESERVED = 0 (ASSEMBLY_ACTIVE removed)
        mailbox_busy,                 // [5] MAILBOX_BUSY
        new_frame,                    // [4] NEW_FRAME
        hold_valid,                   // [3] HOLD_VALID
        live_valid,                   // [2] LIVE_VALID
        engine_enabled_pclk,          // [1] ENGINE_ENABLED
        enable_reg                    // [0] ENABLE_REQ
    };

    // -------------------------------------------------------------------------
    // APB PRDATA Read Mux
    // -------------------------------------------------------------------------
    always @(*) begin
        PRDATA = 32'd0;
        if (apb_access && !PWRITE && legal_access) begin
            case (off)
                16'h0000: PRDATA = 32'h6170622D;         // "apb-"
                16'h0004: PRDATA = 32'h61646320;         // "adc "
                16'h0008: PRDATA = 32'h00020000;         // VERSION 2.0
                16'h000C: PRDATA = {31'd0, enable_reg};
                16'h0010: PRDATA = adc_status_val;
                16'h0014: PRDATA = hold_seq;
                16'h0018: PRDATA = {26'd0, hold_mask};
                16'h001C: PRDATA = {20'd0, hold_ch1};
                16'h0020: PRDATA = {20'd0, hold_ch2};
                16'h0024: PRDATA = {20'd0, hold_ch3};
                16'h0028: PRDATA = {20'd0, hold_ch4};
                16'h002C: PRDATA = {20'd0, hold_ch5};
                16'h0030: PRDATA = {20'd0, hold_ch6};
                16'h0034: PRDATA = live_seq;
                16'h0038: PRDATA = {26'd0, live_mask};
                16'h003C: PRDATA = 32'h00000003;         // ACTIVE_MASK = CH1|CH2
                16'h0040: PRDATA = {20'd0, joy_center_x};
                16'h0044: PRDATA = {20'd0, joy_center_y};
                16'h0048: PRDATA = {20'd0, joy_deadzone};
                16'h004C: PRDATA = {26'd0, joy_status_i};
                16'h0060: PRDATA = frame_count_reg;
                16'h0064: PRDATA = {28'd0, error_status_reg};
                default:  PRDATA = 32'd0;
            endcase
        end
    end

endmodule
