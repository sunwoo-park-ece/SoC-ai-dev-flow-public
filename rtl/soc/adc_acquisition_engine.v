`timescale 1ns/1ps

// Project-local source-domain owner for the MAX 10 ADC command interface.
// P11B B1 implements only CH1 -> CH2 acquisition and frame holding; CDC and
// the PCLK-visible error/status transfer are owned by the later integration.
module adc_acquisition_engine (
    input  wire        adc_sys_clk,
    input  wire        adc_reset_n,
    input  wire        enable,
    // Source-domain state acknowledgement. Remains asserted while an accepted
    // command drains or an offered frame waits for downstream acceptance.
    output wire        engine_enabled,

    output wire        command_valid,
    output wire [4:0]  command_channel,
    output wire        command_startofpacket,
    output wire        command_endofpacket,
    input  wire        command_ready,

    input  wire        response_valid,
    input  wire [4:0]  response_channel,
    input  wire [11:0] response_data,
    input  wire        response_startofpacket,
    input  wire        response_endofpacket,

    output reg         frame_valid,
    input  wire        frame_ready,
    output reg  [31:0] frame_seq,
    output reg  [5:0]  valid_mask,
    output reg  [71:0] samples_flat,

    // One-cycle source-domain events. Bit positions match P11 ERROR_STATUS:
    // [0] UNEXPECTED_CHANNEL, [1] DUPLICATE_CHANNEL,
    // [2] ORDER_ERROR, [3] PACKET_ERROR.
    output reg  [3:0]  error_event
);

    localparam [3:0] ERR_UNEXPECTED_CHANNEL = 4'b0001;
    localparam [3:0] ERR_DUPLICATE_CHANNEL = 4'b0010;
    localparam [3:0] ERR_ORDER_ERROR        = 4'b0100;
    localparam [3:0] ERR_PACKET_ERROR       = 4'b1000;

    localparam [2:0] ST_DISABLED   = 3'd0;
    localparam [2:0] ST_ISSUE_CH1  = 3'd1;
    localparam [2:0] ST_WAIT_CH1   = 3'd2;
    localparam [2:0] ST_ISSUE_CH2  = 3'd3;
    localparam [2:0] ST_WAIT_CH2   = 3'd4;
    localparam [2:0] ST_FRAME_HOLD = 3'd5;
    localparam [2:0] ST_DRAIN_CH1  = 3'd6;
    localparam [2:0] ST_DRAIN_CH2  = 3'd7;

    reg [2:0] state;
    reg [11:0] sample_ch1;

    assign engine_enabled = adc_reset_n && (state != ST_DISABLED);

    assign command_valid = enable &&
                           ((state == ST_ISSUE_CH1) || (state == ST_ISSUE_CH2));
    assign command_channel = (state == ST_ISSUE_CH2) ? 5'd2 : 5'd1;
    assign command_startofpacket = 1'b1;
    assign command_endofpacket = 1'b1;

    task clear_partial_frame;
        begin
            sample_ch1 <= 12'd0;
            valid_mask <= 6'b000000;
        end
    endtask

    task reject_response;
        input [3:0] reason;
        begin
            error_event <= reason;
            clear_partial_frame;
            frame_valid <= 1'b0;
            state <= enable ? ST_ISSUE_CH1 : ST_DISABLED;
        end
    endtask

    always @(posedge adc_sys_clk or negedge adc_reset_n) begin
        if (!adc_reset_n) begin
            state <= ST_DISABLED;
            sample_ch1 <= 12'd0;
            frame_valid <= 1'b0;
            frame_seq <= 32'd0;
            valid_mask <= 6'b000000;
            samples_flat <= 72'd0;
            error_event <= 4'b0000;
        end else begin
            error_event <= 4'b0000;

            case (state)
                ST_DISABLED: begin
                    frame_valid <= 1'b0;
                    clear_partial_frame;
                    if (enable)
                        state <= ST_ISSUE_CH1;
                end

                ST_ISSUE_CH1: begin
                    if (!enable) begin
                        clear_partial_frame;
                        state <= ST_DISABLED;
                    end else if (command_ready) begin
                        state <= ST_WAIT_CH1;
                    end
                end

                ST_WAIT_CH1: begin
                    if (response_valid) begin
                        if (!enable) begin
                            clear_partial_frame;
                            state <= ST_DISABLED;
                        end else if (!response_startofpacket || !response_endofpacket) begin
                            reject_response(ERR_PACKET_ERROR);
                        end else if (response_channel == 5'd2) begin
                            reject_response(ERR_ORDER_ERROR);
                        end else if (response_channel != 5'd1) begin
                            reject_response(ERR_UNEXPECTED_CHANNEL);
                        end else begin
                            sample_ch1 <= response_data;
                            valid_mask <= 6'b000001;
                            state <= ST_ISSUE_CH2;
                        end
                    end else if (!enable) begin
                        clear_partial_frame;
                        state <= ST_DRAIN_CH1;
                    end
                end

                ST_ISSUE_CH2: begin
                    if (!enable) begin
                        clear_partial_frame;
                        state <= ST_DISABLED;
                    end else if (command_ready) begin
                        state <= ST_WAIT_CH2;
                    end
                end

                ST_WAIT_CH2: begin
                    if (response_valid) begin
                        if (!enable) begin
                            clear_partial_frame;
                            state <= ST_DISABLED;
                        end else if (!response_startofpacket || !response_endofpacket) begin
                            reject_response(ERR_PACKET_ERROR);
                        end else if (response_channel == 5'd1) begin
                            reject_response(ERR_DUPLICATE_CHANNEL);
                        end else if (response_channel != 5'd2) begin
                            reject_response(ERR_UNEXPECTED_CHANNEL);
                        end else begin
                            frame_seq <= frame_seq + 32'd1;
                            valid_mask <= 6'b000011;
                            samples_flat <= {48'd0, response_data, sample_ch1};
                            frame_valid <= 1'b1;
                            state <= ST_FRAME_HOLD;
                        end
                    end else if (!enable) begin
                        clear_partial_frame;
                        state <= ST_DRAIN_CH2;
                    end
                end

                ST_FRAME_HOLD: begin
                    if (frame_valid && frame_ready) begin
                        frame_valid <= 1'b0;
                        clear_partial_frame;
                        state <= enable ? ST_ISSUE_CH1 : ST_DISABLED;
                    end
                end

                ST_DRAIN_CH1: begin
                    if (response_valid) begin
                        clear_partial_frame;
                        state <= enable ? ST_ISSUE_CH1 : ST_DISABLED;
                    end
                end

                ST_DRAIN_CH2: begin
                    if (response_valid) begin
                        clear_partial_frame;
                        state <= enable ? ST_ISSUE_CH1 : ST_DISABLED;
                    end
                end

                default: begin
                    state <= ST_DISABLED;
                    frame_valid <= 1'b0;
                    clear_partial_frame;
                end
            endcase
        end
    end

endmodule
