`timescale 1ns/1ps
module tb_vram_model;
    reg wrclock = 1'b0;
    reg rdclock = 1'b0;
    always #5 wrclock = ~wrclock;
    always #7 rdclock = ~rdclock;

    reg [31:0] data = 32'd0;
    reg rd_aclr = 1'b1;
    reg [18:0] rdaddress = 19'd0;
    reg [13:0] wraddress = 14'd0;
    reg wren = 1'b0;
    wire q;

    VRAM dut (.*);

    task write_word(input [13:0] addr, input [31:0] value);
        begin
            @(negedge wrclock); wraddress = addr; data = value; wren = 1'b1;
            @(negedge wrclock); wren = 1'b0;
        end
    endtask

    task read_bit(input [18:0] addr, input expected);
        begin
            @(negedge rdclock); rdaddress = addr;
            @(posedge rdclock); #1;
            if (q !== expected) begin
                $display("FAIL VRAM addr=%0d got=%b expected=%b", addr, q, expected);
                $fatal(1);
            end
        end
    endtask

    initial begin
        #3; rd_aclr = 1'b0;
        write_word(14'd7, 32'h8000_0001);
        read_bit((19'(7*32 + 0)), 1'b1);
        read_bit((19'(7*32 + 1)), 1'b0);
        read_bit((19'(7*32 + 31)), 1'b1);
        write_word(14'h3fff, 32'h0000_0002);
        read_bit(19'h7ffe1, 1'b1);

        rd_aclr = 1'b1; #1;
        if (q !== 1'b0) $fatal(1, "VRAM read clear failed");
        rd_aclr = 1'b0;
        read_bit((19'(7*32 + 31)), 1'b1);
        $display("SUMMARY: PASS VRAM model");
        $finish;
    end
endmodule
