// APB-controlled 6-digit 7-segment display.
// HEX output order is HEX5..HEX0, active-low segment encoding {g,f,e,d,c,b,a}.
module APB_HEX_display (
    input  wire        PCLK,
    input  wire        PRESETn,

    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,

    output reg  [31:0] PRDATA,
    output wire        PREADY,

    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);
    localparam [15:0] REG_VALUE    = 16'h0000; // VALUE_REG[23:0], HEX5..HEX0
    localparam [15:0] REG_CTRL     = 16'h0004; // CTRL_REG[0]=enable, [1]=raw_mode
    localparam [15:0] REG_RAW_LOW  = 16'h0008; // RAW_LOW,  HEX2..HEX0 raw segments
    localparam [15:0] REG_RAW_HIGH = 16'h000c; // RAW_HIGH, HEX5..HEX3 raw segments

    localparam CTRL_ENABLE   = 0;
    localparam CTRL_RAW_MODE = 1;

    reg [23:0] value_reg;
    // CTRL has only ENABLE and RAW_MODE.  Reserved bits [31:2] are RAZ/WI.
    reg [1:0] ctrl_reg;
    reg [20:0] raw_low_reg;
    reg [20:0] raw_high_reg;

    wire display_enable = ctrl_reg[CTRL_ENABLE];
    wire raw_mode       = ctrl_reg[CTRL_RAW_MODE];

    assign PREADY = 1'b1;

    function [6:0] hex_to_seg;
        input [3:0] value;
        begin
            case (value)
                4'h0: hex_to_seg = 7'b1000000;
                4'h1: hex_to_seg = 7'b1111001;
                4'h2: hex_to_seg = 7'b0100100;
                4'h3: hex_to_seg = 7'b0110000;
                4'h4: hex_to_seg = 7'b0011001;
                4'h5: hex_to_seg = 7'b0010010;
                4'h6: hex_to_seg = 7'b0000010;
                4'h7: hex_to_seg = 7'b1111000;
                4'h8: hex_to_seg = 7'b0000000;
                4'h9: hex_to_seg = 7'b0010000;
                4'hA: hex_to_seg = 7'b0001000;
                4'hB: hex_to_seg = 7'b0000011;
                4'hC: hex_to_seg = 7'b1000110;
                4'hD: hex_to_seg = 7'b0100001;
                4'hE: hex_to_seg = 7'b0000110;
                4'hF: hex_to_seg = 7'b0001110;
                default: hex_to_seg = 7'b1111111;
            endcase
        end
    endfunction

    wire [6:0] dec_hex0 = hex_to_seg(value_reg[3:0]);
    wire [6:0] dec_hex1 = hex_to_seg(value_reg[7:4]);
    wire [6:0] dec_hex2 = hex_to_seg(value_reg[11:8]);
    wire [6:0] dec_hex3 = hex_to_seg(value_reg[15:12]);
    wire [6:0] dec_hex4 = hex_to_seg(value_reg[19:16]);
    wire [6:0] dec_hex5 = hex_to_seg(value_reg[23:20]);

    wire [6:0] out_hex0 = raw_mode ? raw_low_reg[6:0]    : dec_hex0;
    wire [6:0] out_hex1 = raw_mode ? raw_low_reg[13:7]   : dec_hex1;
    wire [6:0] out_hex2 = raw_mode ? raw_low_reg[20:14]  : dec_hex2;
    wire [6:0] out_hex3 = raw_mode ? raw_high_reg[6:0]   : dec_hex3;
    wire [6:0] out_hex4 = raw_mode ? raw_high_reg[13:7]  : dec_hex4;
    wire [6:0] out_hex5 = raw_mode ? raw_high_reg[20:14] : dec_hex5;

    assign HEX0 = display_enable ? out_hex0 : 7'b1111111;
    assign HEX1 = display_enable ? out_hex1 : 7'b1111111;
    assign HEX2 = display_enable ? out_hex2 : 7'b1111111;
    assign HEX3 = display_enable ? out_hex3 : 7'b1111111;
    assign HEX4 = display_enable ? out_hex4 : 7'b1111111;
    assign HEX5 = display_enable ? out_hex5 : 7'b1111111;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            value_reg    <= 24'h000000;
            ctrl_reg     <= 2'b01; // enable=1, raw_mode=0
            raw_low_reg  <= {3{7'b1111111}};
            raw_high_reg <= {3{7'b1111111}};
        end else if (PSEL && PENABLE && PWRITE) begin
            case (PADDR[15:0])
                REG_VALUE:    value_reg    <= PWDATA[23:0];
                REG_CTRL:     ctrl_reg     <= PWDATA[1:0];
                REG_RAW_LOW:  raw_low_reg  <= PWDATA[20:0];
                REG_RAW_HIGH: raw_high_reg <= PWDATA[20:0];
                default: ;
            endcase
        end
    end

    always @(*) begin
        if (PSEL && PENABLE && !PWRITE) begin
            case (PADDR[15:0])
                REG_VALUE:    PRDATA = {8'h00, value_reg};
                REG_CTRL:     PRDATA = {30'b0, ctrl_reg};
                REG_RAW_LOW:  PRDATA = {11'h000, raw_low_reg};
                REG_RAW_HIGH: PRDATA = {11'h000, raw_high_reg};
                default:      PRDATA = 32'h00000000;
            endcase
        end else begin
            PRDATA = 32'h00000000;
        end
    end
endmodule
