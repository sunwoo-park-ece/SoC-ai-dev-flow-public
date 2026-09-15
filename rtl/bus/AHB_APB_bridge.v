// AHB-to-APB bridge with registered request state and combinational bus outputs.

module AHB_APB_bridge (
    input HCLK,
    input HRESETn,

    // AHB Slave Interface
    input [31:0]      HADDR,
    input             HWRITE,
    input [1:0]       HTRANS,
    input [2:0]       HSIZE,
    input [31:0]      HWDATA,
    input             HSEL,
    input             HREADY_IN,
    output reg [31:0] HRDATA,
    output reg        HREADY,
    output reg [1:0]  HRESP,

    // APB Master Interface
    output            PCLK,
    output            PRESETn,
    output reg [31:0] PADDR,
    output reg        PWRITE,
    output reg        PENABLE,
    output reg [15:0] PSEL,
    output reg [31:0] PWDATA,
    input [31:0]      PRDATA,
    input             PREADY,
    input             PSLVERR
); 

    assign PCLK = HCLK;
    assign PRESETn = HRESETn;
    localparam [1:0] IDLE = 2'b00, SETUP = 2'b01,
                     ACCESS = 2'b10, ERROR_FINAL = 2'b11;

    reg [1:0] state, next_state;
    reg [31:0] addr_reg;
    reg        write_reg;
    reg [2:0]  size_reg;
    reg [31:0] wdata_reg;
    wire request_valid = (size_reg == 3'b010) &&
                         (addr_reg[1:0] == 2'b00) && canonical_offset(addr_reg);
    wire access_done = !request_valid || PREADY;
    wire access_error = !request_valid || (PREADY && PSLVERR);


	// APB 슬레이브 주소 디코딩 함수
	function [15:0] decode_psel;
    input [31:0] addr;
    begin
        decode_psel = (addr[31:20] == 12'h400) ?
                      (16'h0001 << addr[19:16]) : 16'h0000;
    end
endfunction

    // Validate the full canonical offset before exposing PSEL to a real
    // peripheral. Slots 10-15 remain reserved.
    function canonical_offset;
        input [31:0] addr;
        reg [15:0] off;
        begin
            off = addr[15:0];
            canonical_offset = 1'b0;
            if (addr[31:20] == 12'h400) begin
                case (addr[19:16])
                    4'h0, 4'h2, 4'h6, 4'h7:
                        canonical_offset = (off == 16'h0000 || off == 16'h0004 ||
                                            off == 16'h0008 || off == 16'h000c);
                    4'h1:
                        canonical_offset = (off <= 16'h001c && off[1:0] == 2'b00);
                    4'h3:
                        canonical_offset = (off == 16'h0000 || off == 16'h0004);
                    4'h8:
                        canonical_offset = (off == 16'h0000 || off == 16'h0004 ||
                                            off == 16'h0008);
                    4'h9:
                        canonical_offset = (off == 16'h0000);
                    4'h4:
                        canonical_offset = (off == 16'h0000 || off == 16'h0004 ||
                                            off == 16'h0008 || off == 16'h000c ||
                                            off == 16'h0010 ||
                                            (off >= 16'h0020 && off <= 16'h008c && off[1:0] == 2'b00));
                    4'h5:
                        canonical_offset = (off <= 16'h0038 && off[1:0] == 2'b00);
                    default: canonical_offset = 1'b0;
                endcase
            end
        end
    endfunction
	 

    // ──────────────────────────────────────────────────
    // 1. Sequential Block (상태 및 데이터 캡처)
    // ──────────────────────────────────────────────────
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            state <= IDLE;
            addr_reg <= 32'h0;
            write_reg <= 1'b0;
            size_reg <= 3'b010;
            wdata_reg <= 32'h0;
        end else begin
            state <= next_state;

            // Accept an address only when the global data phase advances.
            // ERROR_FINAL always cancels the following address phase.
            if (HREADY_IN && HSEL && HTRANS[1] &&
                ((state == IDLE) || (state == ACCESS && access_done && !access_error))) begin
                addr_reg  <= HADDR;
                write_reg <= HWRITE;
                size_reg <= HSIZE;
            end
            if (state == SETUP && write_reg)
                wdata_reg <= HWDATA;
        end
    end

    // ──────────────────────────────────────────────────
    // 2. Next State Logic (상태 전이)
    // ──────────────────────────────────────────────────
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: if (HREADY_IN && HSEL && HTRANS[1]) next_state = SETUP;
            SETUP: next_state = ACCESS;
            ACCESS: begin
                if (access_done)
                    next_state = access_error ? ERROR_FINAL :
                                 ((HREADY_IN && HSEL && HTRANS[1]) ? SETUP : IDLE);
            end
            ERROR_FINAL: next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // Keep APB controls independent of APB responses. This also avoids
    // creating a combinational path from a peripheral PRDATA/PREADY back to
    // its own PSEL through an over-broad output block.
    always @(*) begin
        PSEL    = ((state == SETUP || state == ACCESS) && request_valid) ?
                  decode_psel(addr_reg) : 16'b0;
        PENABLE = (state == ACCESS);
        PADDR   = addr_reg;
        PWRITE  = write_reg;
        PWDATA  = (state == SETUP) ? HWDATA : wdata_reg;
    end

    always @(*) begin
        HREADY  = 1'b1;
        HRESP   = 2'b00;
        HRDATA = 32'h0;

        case (state)
            IDLE: HREADY = 1'b1;
            SETUP: HREADY = 1'b0;
            ACCESS: begin
                if (access_done) begin
                    if (access_error) begin
                        HRESP = 2'b01;
                        HREADY = 1'b0; // first AHB ERROR response cycle
                    end else begin
                        HREADY = 1'b1;
                        if (!write_reg) HRDATA = PRDATA;
                    end
                end else HREADY = 1'b0;
            end
            ERROR_FINAL: begin
                HRESP = 2'b01;
                HREADY = 1'b1;
            end
            default: HREADY = 1'b1;
        endcase
    end

endmodule
