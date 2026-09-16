`timescale 1ns/1ps
module tb_ahb_master_hsize;
    reg EX_memory_read = 0, EX_memory_write = 0;
    reg [31:0] EX_alu_result = 32'h10000000, MEM_read_data2 = 0, HRDATA = 0;
    reg [2:0] EX_funct3 = 0;
    reg HREADY = 1;
    reg [3:0] CUSTOM_WRITE_MASK_IN = 0;
    wire [31:0] HRDATA_to_CPU, HADDR, HWDATA;
    wire bus_stall_req, HWRITE;
    wire [1:0] HTRANS;
    wire [2:0] HSIZE, HBURST;
    wire [3:0] CUSTOM_WRITE_MASK_OUT;
    AHB_Master_Interface dut (.*);
    task expect_size(input read_op, input [2:0] funct3, input [2:0] expected);
        begin
            EX_memory_read=read_op; EX_memory_write=!read_op; EX_funct3=funct3;
            #1;
            if (HSIZE !== expected || HTRANS !== 2'b10)
                $fatal(1,"read=%b funct3=%b size=%b trans=%b expected=%b",
                       read_op,funct3,HSIZE,HTRANS,expected);
        end
    endtask
    initial begin
        expect_size(1,3'b000,3'b000); // LB
        expect_size(1,3'b100,3'b000); // LBU
        expect_size(1,3'b001,3'b001); // LH
        expect_size(1,3'b101,3'b001); // LHU
        expect_size(1,3'b010,3'b010); // LW
        expect_size(0,3'b000,3'b000); // SB
        expect_size(0,3'b001,3'b001); // SH
        expect_size(0,3'b010,3'b010); // SW
        EX_alu_result=32'h10000001; EX_funct3=3'b010; #1;
        if (HTRANS !== 2'b00) $fatal(1,"misaligned CPU word reached AHB");
        EX_alu_result=32'h10000000; EX_funct3=3'b111; #1;
        if (HSIZE !== 3'b111) $fatal(1,"unsupported encoding silently mapped to word");
        EX_memory_read=0; EX_memory_write=0; #1;
        if (HTRANS !== 0 || HSIZE !== 3'b010) $fatal(1,"IDLE size/transfer");
        $display("SUMMARY: PASS LB/LBU/LH/LHU/LW/SB/SH/SW HSIZE");
        $finish;
    end
endmodule
