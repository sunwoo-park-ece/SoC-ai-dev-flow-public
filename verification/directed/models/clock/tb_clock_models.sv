`timescale 1ns/1ps
module tb_clock_models;
    reg clk_50 = 1'b0;
    reg spi_reset = 1'b1;
    wire pixel_clk, pixel_locked, spi_clk, spi_phase_clk;
    integer t_first;

    always #10 clk_50 = ~clk_50;
    vga_pll u_vga (.inclk0(clk_50), .c0(pixel_clk), .locked(pixel_locked));
    spi_pll u_spi (.areset(spi_reset), .inclk0(clk_50),
                   .c0(spi_clk), .c1(spi_phase_clk));

    initial begin
        #12; spi_reset = 1'b0;
        wait (pixel_locked === 1'b1);
        repeat (2) @(posedge pixel_clk);
        t_first = $time;
        @(posedge pixel_clk);
        if ($time - t_first != 40) $fatal(1, "VGA clock is not 25 MHz");

        repeat (2) @(negedge spi_clk);
        @(posedge spi_phase_clk);
        if (spi_clk !== 1'b0) $fatal(1, "SPI phase clock did not lead state clock");
        @(posedge spi_clk);
        if (spi_phase_clk !== 1'b1) $fatal(1, "SPI phase order invalid");
        t_first = $time;
        @(posedge spi_clk);
        if ($time - t_first != 500) $fatal(1, "SPI clock is not 2 MHz");
        $display("SUMMARY: PASS clock models");
        $finish;
    end
endmodule
