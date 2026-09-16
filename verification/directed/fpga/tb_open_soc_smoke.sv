`timescale 1ns/1ps

// Structural mixed-language smoke test. Internal debounced reset deliberately
// remains asserted; this does not claim firmware or AES functional coverage.
module tb_open_soc_smoke;
    reg clk = 1'b0;
    reg [1:0] KEY = 2'b10;
    reg [9:0] SW = 10'b0;
    reg [2:1] G_SENSOR_INT = 2'b0;
    reg G_SENSOR_SDO = 1'b0;
    reg lora_rx = 1'b1;
    reg lora_aux = 1'b0;
    reg uart_rx = 1'b1;
    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire G_SENSOR_CS_N, G_SENSOR_SCLK, G_SENSOR_SDI;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire VGA_HS, VGA_VS, lora_tx, uart_tx;

    always #10 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI),
        .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    initial begin
        #500;
        KEY[0] = 1'b1;
        #500;
        $display("SUMMARY: PASS mixed-language SoC structural smoke");
        $finish;
    end
endmodule
