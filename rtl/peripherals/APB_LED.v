module APB_LED (
    input wire PCLK, PRESETn,
    input wire [31:0] PADDR, PWDATA,
    input wire PWRITE, PSEL, PENABLE,
    output reg [31:0] PRDATA,
    output wire PREADY,
    output reg [9:0] LEDR
);
    assign PREADY = 1'b1;
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) LEDR <= 10'b0;
        else if (PSEL && PENABLE && PWRITE && PADDR[15:0] == 16'h0000)
            LEDR <= PWDATA[9:0];
    end
    always @(*) begin
        PRDATA = 32'b0;
        if (PSEL && PENABLE && !PWRITE && PADDR[15:0] == 16'h0000)
            PRDATA = {22'b0,LEDR};
    end
endmodule
