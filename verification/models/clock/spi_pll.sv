// OPEN_SIM phase/frequency abstraction only. PRIVATE_QUARTUS uses the vendor PLL.
module spi_pll (
    input  wire areset,
    input  wire inclk0,
    output wire c0,
    output wire c1
);
    reg [4:0] phase;

    initial phase = 5'd0;
    always @(posedge inclk0 or posedge areset) begin
        if (areset)
            phase <= 5'd0;
        else if (phase == 5'd24)
            phase <= 5'd0;
        else
            phase <= phase + 5'd1;
    end

    // Divide by 25. c1 leads c0 by two input-clock periods in this model.
    assign c0 = (phase < 5'd13);
    assign c1 = ((phase >= 5'd23) || (phase < 5'd11));
endmodule
