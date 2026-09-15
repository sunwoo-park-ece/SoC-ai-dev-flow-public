`timescale 1ns/1ps

module APB_ADC_Joystick_Controller (
    input  wire        PCLK,
    input  wire        PRESETn,

    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,

    output wire        adc_command_valid,
    output wire [4:0]  adc_command_channel,
    output wire        adc_command_startofpacket,
    output wire        adc_command_endofpacket,
    input  wire        adc_command_ready,

    input  wire        adc_response_valid,
    input  wire [4:0]  adc_response_channel,
    input  wire [11:0] adc_response_data,
    input  wire        adc_response_startofpacket,
    input  wire        adc_response_endofpacket
);

    assign PREADY = 1'b1;

    localparam [5:0] ADDR_NAME0        = 6'h00; // 0x00
    localparam [5:0] ADDR_NAME1        = 6'h01; // 0x04
    localparam [5:0] ADDR_VERSION      = 6'h02; // 0x08
    localparam [5:0] ADDR_CTRL         = 6'h03; // 0x0c
    localparam [5:0] ADDR_STATUS       = 6'h04; // 0x10
    localparam [5:0] ADDR_X_CHANNEL    = 6'h05; // 0x14
    localparam [5:0] ADDR_Y_CHANNEL    = 6'h06; // 0x18
    localparam [5:0] ADDR_X_RAW        = 6'h07; // 0x1c
    localparam [5:0] ADDR_Y_RAW        = 6'h08; // 0x20
    localparam [5:0] ADDR_CENTER_X     = 6'h09; // 0x24
    localparam [5:0] ADDR_CENTER_Y     = 6'h0a; // 0x28
    localparam [5:0] ADDR_DEADZONE     = 6'h0b; // 0x2c
    localparam [5:0] ADDR_DIR_STATUS   = 6'h0c; // 0x30
    localparam [5:0] ADDR_SAMPLE_COUNT = 6'h0d; // 0x34
    localparam [5:0] ADDR_RESP_INFO    = 6'h0e; // 0x38

    localparam CTRL_ENABLE_BIT      = 0;
    localparam CTRL_CLEAR_FLAGS_BIT = 1;
    localparam CTRL_CLEAR_COUNT_BIT = 2;

    localparam [31:0] CORE_NAME0   = 32'h6170622d; // "apb-"
    localparam [31:0] CORE_NAME1   = 32'h6a6f7920; // "joy "
    localparam [31:0] CORE_VERSION = 32'h302e3031; // "0.01"

    reg        enable_reg;
    reg        scan_axis_reg; // 0: X command, 1: Y command
    reg        x_valid_reg;
    reg        y_valid_reg;
    reg        unexpected_channel_reg;
    reg [4:0]  x_channel_reg;
    reg [4:0]  y_channel_reg;
    reg [4:0]  last_response_channel_reg;
    reg [11:0] x_raw_reg;
    reg [11:0] y_raw_reg;
    reg [11:0] center_x_reg;
    reg [11:0] center_y_reg;
    reg [11:0] deadzone_reg;
    reg [31:0] sample_count_reg;
    reg        sample_sop_reg;
    reg        sample_eop_reg;

    wire [5:0] addr_word = PADDR[7:2];
    wire       apb_write = PSEL && PENABLE && PWRITE;
    wire       apb_read  = PSEL && PENABLE && !PWRITE;
    wire       command_fire = adc_command_valid && adc_command_ready;

    wire [12:0] x_raw_ext      = {1'b0, x_raw_reg};
    wire [12:0] y_raw_ext      = {1'b0, y_raw_reg};
    wire [12:0] center_x_ext   = {1'b0, center_x_reg};
    wire [12:0] center_y_ext   = {1'b0, center_y_reg};
    wire [12:0] deadzone_ext   = {1'b0, deadzone_reg};
    wire [12:0] x_high_limit   = center_x_ext + deadzone_ext;
    wire [12:0] y_high_limit   = center_y_ext + deadzone_ext;
    wire [12:0] x_low_compare  = x_raw_ext + deadzone_ext;
    wire [12:0] y_low_compare  = y_raw_ext + deadzone_ext;

    wire right_cmd    = x_valid_reg && (x_raw_ext > x_high_limit);
    wire left_cmd     = x_valid_reg && (x_low_compare < center_x_ext);
    wire forward_cmd  = y_valid_reg && (y_raw_ext > y_high_limit);
    wire backward_cmd = y_valid_reg && (y_low_compare < center_y_ext);

    assign adc_command_valid = enable_reg;
    assign adc_command_channel = scan_axis_reg ? y_channel_reg : x_channel_reg;
    assign adc_command_startofpacket = 1'b1;
    assign adc_command_endofpacket = 1'b1;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            enable_reg              <= 1'b0;
            scan_axis_reg           <= 1'b0;
            x_valid_reg             <= 1'b0;
            y_valid_reg             <= 1'b0;
            unexpected_channel_reg  <= 1'b0;
            x_channel_reg           <= 5'd1;
            y_channel_reg           <= 5'd2;
            last_response_channel_reg <= 5'd0;
            x_raw_reg               <= 12'd0;
            y_raw_reg               <= 12'd0;
            center_x_reg            <= 12'd2048;
            center_y_reg            <= 12'd2048;
            deadzone_reg            <= 12'd300;
            sample_count_reg        <= 32'd0;
            sample_sop_reg          <= 1'b0;
            sample_eop_reg          <= 1'b0;
        end else begin
            if (apb_write) begin
                case (addr_word)
                    ADDR_CTRL: begin
                        enable_reg <= PWDATA[CTRL_ENABLE_BIT];

                        if (PWDATA[CTRL_CLEAR_FLAGS_BIT]) begin
                            x_valid_reg            <= 1'b0;
                            y_valid_reg            <= 1'b0;
                            unexpected_channel_reg <= 1'b0;
                        end

                        if (PWDATA[CTRL_CLEAR_COUNT_BIT])
                            sample_count_reg <= 32'd0;
                    end

                    ADDR_X_CHANNEL: x_channel_reg <= PWDATA[4:0];
                    ADDR_Y_CHANNEL: y_channel_reg <= PWDATA[4:0];
                    ADDR_CENTER_X:  center_x_reg  <= PWDATA[11:0];
                    ADDR_CENTER_Y:  center_y_reg  <= PWDATA[11:0];
                    ADDR_DEADZONE:  deadzone_reg  <= PWDATA[11:0];

                    default: ;
                endcase
            end

            if (command_fire)
                scan_axis_reg <= ~scan_axis_reg;

            if (adc_response_valid) begin
                last_response_channel_reg <= adc_response_channel;
                sample_sop_reg <= adc_response_startofpacket;
                sample_eop_reg <= adc_response_endofpacket;
                sample_count_reg <= sample_count_reg + 1'b1;

                if (adc_response_channel == x_channel_reg) begin
                    x_raw_reg <= adc_response_data;
                    x_valid_reg <= 1'b1;
                end else if (adc_response_channel == y_channel_reg) begin
                    y_raw_reg <= adc_response_data;
                    y_valid_reg <= 1'b1;
                end else begin
                    unexpected_channel_reg <= 1'b1;
                end
            end
        end
    end

    always @(*) begin
        PRDATA = 32'h0;
        if (apb_read) begin
            case (addr_word)
                ADDR_NAME0:   PRDATA = CORE_NAME0;
                ADDR_NAME1:   PRDATA = CORE_NAME1;
                ADDR_VERSION: PRDATA = CORE_VERSION;

                ADDR_CTRL: begin
                    PRDATA = {29'h0, 1'b0, 1'b0, enable_reg};
                end

                ADDR_STATUS: begin
                    PRDATA = {
                        4'h0,
                        y_channel_reg,
                        x_channel_reg,
                        last_response_channel_reg,
                        adc_response_valid,
                        command_fire,
                        adc_command_ready,
                        unexpected_channel_reg,
                        y_valid_reg,
                        x_valid_reg,
                        scan_axis_reg,
                        enable_reg
                    };
                end

                ADDR_X_CHANNEL: PRDATA = {27'h0, x_channel_reg};
                ADDR_Y_CHANNEL: PRDATA = {27'h0, y_channel_reg};
                ADDR_X_RAW:     PRDATA = {19'h0, x_valid_reg, x_raw_reg};
                ADDR_Y_RAW:     PRDATA = {19'h0, y_valid_reg, y_raw_reg};
                ADDR_CENTER_X:  PRDATA = {20'h0, center_x_reg};
                ADDR_CENTER_Y:  PRDATA = {20'h0, center_y_reg};
                ADDR_DEADZONE:  PRDATA = {20'h0, deadzone_reg};

                ADDR_DIR_STATUS: begin
                    PRDATA = {
                        26'h0,
                        y_valid_reg,
                        x_valid_reg,
                        right_cmd,
                        left_cmd,
                        backward_cmd,
                        forward_cmd
                    };
                end

                ADDR_SAMPLE_COUNT: PRDATA = sample_count_reg;

                ADDR_RESP_INFO: begin
                    PRDATA = {
                        11'h0,
                        sample_eop_reg,
                        sample_sop_reg,
                        adc_response_endofpacket,
                        adc_response_startofpacket,
                        adc_response_channel,
                        adc_response_data
                    };
                end

                default: PRDATA = 32'h0;
            endcase
        end
    end

endmodule
