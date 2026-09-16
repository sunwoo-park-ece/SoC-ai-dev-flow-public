`timescale 1ns/1ps
module tb_register_file;
    reg clk = 1'b0;
    reg clk_enable = 1'b1;
    reg [4:0] read_reg1 = 5'd0;
    reg [4:0] read_reg2 = 5'd0;
    reg write_enable = 1'b0;
    reg [4:0] write_reg = 5'd0;
    reg [31:0] write_data = 32'd0;
    reg debug_reset = 1'b1;
    wire [31:0] read_data1, read_data2;
    wire [31:0] debug_X1, debug_X2, debug_X3, debug_X4;

    always #5 clk = ~clk;
    RegisterFile dut (.*);

    initial begin
        #2; debug_reset = 1'b0;
        read_reg1 = 5'd0;
        write_enable = 1'b1; write_reg = 5'd0; write_data = 32'hffff_ffff;
        @(posedge clk); #1;
        if (read_data1 !== 32'd0 || dut.registers[0] !== 32'd0) $fatal(1, "x0 changed");

        @(negedge clk);
        write_reg = 5'd5; write_data = 32'h1234_5678;
        read_reg1 = 5'd5; read_reg2 = 5'd5;
        #1;
        if (read_data1 !== write_data || read_data2 !== write_data)
            $fatal(1, "same-cycle forwarding");
        @(posedge clk); #1;
        write_enable = 1'b0;
        if (read_data1 !== 32'h1234_5678) $fatal(1, "register write/read");

        @(negedge clk);
        write_enable = 1'b1; write_reg = 5'd15; write_data = 32'ha5a5_5a5a;
        @(posedge clk); #1;
        write_enable = 1'b0;
        @(posedge clk); #1;
        if (debug_X4 !== 32'ha5a5_5a5a) $fatal(1, "debug_X4 tracking");
        debug_reset = 1'b1; #1;
        if (debug_X4 !== 32'd0) $fatal(1, "debug_X4 reset");
        debug_reset = 1'b0;

        clk_enable = 1'b0;
        write_enable = 1'b1; write_reg = 5'd2; write_data = 32'hdead_beef;
        @(posedge clk); #1;
        if (debug_X2 !== 32'd0) $fatal(1, "clk_enable write gate");
        $display("SUMMARY: PASS RegisterFile");
        $finish;
    end
endmodule
