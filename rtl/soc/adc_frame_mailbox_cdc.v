`timescale 1ns/1ps

// P11B component CDC boundary. Both resets must assert together for a system
// reset; either reset assertion aborts the mailbox in both domains.
module adc_frame_mailbox_cdc (
    input  wire        pclk,
    input  wire        pclk_reset_n,
    input  wire        enable_req,
    output wire        engine_enabled_pclk,
    output reg         frame_pulse_pclk,
    output reg  [31:0] frame_seq_pclk,
    output reg  [5:0]  valid_mask_pclk,
    output reg  [71:0] samples_flat_pclk,

    input  wire        adc_sys_clk,
    input  wire        adc_reset_n,
    output wire        engine_enable,
    input  wire        engine_enabled,
    input  wire        frame_valid,
    output wire        frame_ready,
    input  wire [31:0] frame_seq,
    input  wire [5:0]  valid_mask,
    input  wire [71:0] samples_flat,
    output wire        mailbox_busy
);
    wire reset_pair_n = pclk_reset_n && adc_reset_n;
    (* async_reg = "true" *) reg [1:0] source_release;
    (* async_reg = "true" *) reg [1:0] destination_release;
    always @(posedge adc_sys_clk or negedge reset_pair_n) begin
        if (!reset_pair_n) source_release <= 2'b00;
        else source_release <= {source_release[0], 1'b1};
    end
    always @(posedge pclk or negedge reset_pair_n) begin
        if (!reset_pair_n) destination_release <= 2'b00;
        else destination_release <= {destination_release[0], 1'b1};
    end

    (* async_reg = "true" *) reg [1:0] enable_sync;
    (* async_reg = "true" *) reg [1:0] enabled_sync;
    (* async_reg = "true" *) reg [1:0] req_sync;
    (* async_reg = "true" *) reg [1:0] ack_sync;

    reg req_toggle;
    reg ack_toggle;
    reg [1:0] source_state;
    localparam [1:0] SRC_IDLE = 2'd0, SRC_WAIT_ACK = 2'd1,
                     SRC_RELEASE = 2'd2;
    reg [109:0] source_payload;
    reg received_toggle;

    assign engine_enable = enable_sync[1];
    assign mailbox_busy = (source_state != SRC_IDLE);
    assign frame_ready = (source_state == SRC_RELEASE);
    // Source-domain acknowledgement includes both the real engine state and
    // its already-published frame transaction. It cannot fall before ACK.
    wire source_enabled_ack = engine_enabled || mailbox_busy;
    assign engine_enabled_pclk = enabled_sync[1];

    always @(posedge adc_sys_clk or negedge source_release[1]) begin
        if (!source_release[1]) begin
            enable_sync <= 2'b00;
            ack_sync <= 2'b00;
            req_toggle <= 1'b0;
            source_state <= SRC_IDLE;
            source_payload <= 110'd0;
        end else begin
            enable_sync <= {enable_sync[0], enable_req};
            ack_sync <= {ack_sync[0], ack_toggle};
            case (source_state)
                SRC_IDLE: if (frame_valid) begin
                    source_payload <= {frame_seq, valid_mask, samples_flat};
                    req_toggle <= ~req_toggle;
                    source_state <= SRC_WAIT_ACK;
                end
                SRC_WAIT_ACK: if (ack_sync[1] == req_toggle)
                    source_state <= SRC_RELEASE;
                SRC_RELEASE: source_state <= SRC_IDLE;
                default: source_state <= SRC_IDLE;
            endcase
        end
    end

    always @(posedge pclk or negedge destination_release[1]) begin
        if (!destination_release[1]) begin
            enabled_sync <= 2'b00;
            req_sync <= 2'b00;
            ack_toggle <= 1'b0;
            received_toggle <= 1'b0;
            frame_pulse_pclk <= 1'b0;
            frame_seq_pclk <= 32'd0;
            valid_mask_pclk <= 6'd0;
            samples_flat_pclk <= 72'd0;
        end else begin
            enabled_sync <= {enabled_sync[0], source_enabled_ack};
            req_sync <= {req_sync[0], req_toggle};
            frame_pulse_pclk <= 1'b0;
            if (req_sync[1] != received_toggle) begin
                {frame_seq_pclk, valid_mask_pclk, samples_flat_pclk} <= source_payload;
                frame_pulse_pclk <= 1'b1;
                received_toggle <= req_sync[1];
                ack_toggle <= req_sync[1];
            end
        end
    end
endmodule
