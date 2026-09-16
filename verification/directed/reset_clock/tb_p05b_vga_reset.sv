`timescale 1ns/1ps

module tb_p05b_vga_reset;
    reg clock_50 = 1'b0;
    reg hreset_n = 1'b0;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire [3:0] vga_r;
    wire [3:0] vga_g;
    wire [3:0] vga_b;
    wire vga_hs;
    wire vga_vs;

    always #10 clock_50 = ~clock_50;

    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50 (clock_50),
        .HCLK     (clock_50),
        .HRESETn  (hreset_n),
        .HADDR    (32'h0),
        .HWRITE   (1'b0),
        .HTRANS   (2'b00),
        .HWDATA   (32'h0),
        .HSEL     (1'b0),
        .HREADY_IN(1'b1),
        .HRDATA   (hrdata),
        .HREADY   (hready),
        .HRESP    (hresp),
        .VGA_R    (vga_r),
        .VGA_G    (vga_g),
        .VGA_B    (vga_b),
        .VGA_HS   (vga_hs),
        .VGA_VS   (vga_vs)
    );

    task automatic check_condition;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $fatal(1);
            end
        end
    endtask

    initial begin
        #1;
        check_condition(dut.vga_reset_n === 1'b0, "VGA reset is not LOW at cold start");
        check_condition(dut.U_SYNC.oHCNT === 10'd0, "VGA counter is not reset at cold start");

        // System release alone is insufficient: the model PLL must lock and the
        // pclk_25 synchronizer must receive two destination edges.
        #12 hreset_n = 1'b1;
        wait (dut.vga_pll_locked === 1'b1);
        #1 check_condition(dut.vga_reset_n === 1'b0, "VGA reset ignored PLL-lock sequencing");
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b0, "VGA reset released after one pclk edge");
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b1, "VGA reset did not release on pclk_25");
        repeat (4) @(posedge dut.pclk_25);
        #1 check_condition(dut.U_SYNC.oHCNT != 10'd0, "VGA pixel state did not run after release");

        // Lock loss while active must asynchronously reset every pixel-domain
        // consumer, then repeat lock qualification and synchronized release.
        #7 dut.U_PLL.inject_lock_loss(); #1;
        check_condition(dut.vga_pll_locked === 1'b0, "PLL model did not report lock loss");
        check_condition(dut.vga_reset_n === 1'b0, "PLL lock loss did not assert VGA reset");
        check_condition(dut.U_SYNC.oHCNT === 10'd0 && dut.VRAM_ADDR === 19'd0,
               "VGA state was not cleared on lock loss");
        wait (dut.vga_pll_locked === 1'b1);
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b0, "VGA lock reacquisition released too early");
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b1, "VGA reset did not release after reacquisition");

        // A system reset during video activity follows the same immediate assert
        // and pclk_25-local release rule.
        repeat (3) @(posedge dut.pclk_25);
        #5 hreset_n = 1'b0; #1;
        check_condition(dut.vga_reset_n === 1'b0 && dut.U_SYNC.oHCNT === 10'd0,
               "system reset did not immediately reset VGA state");
        #6 hreset_n = 1'b1;
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b0, "system reset release bypassed VGA synchronizer");
        @(posedge dut.pclk_25); #1;
        check_condition(dut.vga_reset_n === 1'b1, "VGA reset did not recover from system reset");

        $display("SUMMARY: PASS P05B VGA lock-qualified reset");
        $finish;
    end
endmodule
