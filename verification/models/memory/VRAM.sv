// Portable OPEN_SIM mixed-width dual-clock framebuffer model.
module VRAM (
    input  wire [31:0] data,
    input  wire        rd_aclr,
    input  wire [18:0] rdaddress,
    input  wire        rdclock,
    input  wire [13:0] wraddress,
    input  wire        wrclock,
    input  wire        wren,
    output reg         q
);
    reg [31:0] words [0:16383];
    integer i;

    initial begin
        q = 1'b0;
        for (i = 0; i < 16384; i = i + 1)
            words[i] = 32'h0;
    end

    always @(posedge wrclock) begin
        if (wren)
            words[wraddress] <= data;
    end

    always @(posedge rdclock or posedge rd_aclr) begin
        if (rd_aclr)
            q <= 1'b0;
        else
            q <= words[rdaddress[18:5]][rdaddress[4:0]];
    end
endmodule
