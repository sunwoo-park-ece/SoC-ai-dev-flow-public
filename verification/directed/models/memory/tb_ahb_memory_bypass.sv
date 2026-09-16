`timescale 1ns/1ps
module tb_ahb_memory_bypass;
    reg HCLK = 1'b0;
    reg HRESETn = 1'b0;
    reg [31:0] HADDR = 32'd0;
    reg HWRITE = 1'b0;
    reg [1:0] HTRANS = 2'b00;
    reg [2:0] HSIZE = 3'b010;
    reg [31:0] HWDATA = 32'd0;
    reg HSEL = 1'b0;
    reg HREADY_IN = 1'b1;
    reg [3:0] byteena = 4'b0000;
    reg BRAM_HAZARD = 1'b0;
    reg MEM_READ_FROM_CPU = 1'b0;
    wire [31:0] HRDATA;
    wire HREADY;
    wire [1:0] HRESP;

    always #5 HCLK = ~HCLK;
    AHB_MEMORY_SLAVE dut (.*);

    task address_phase_write(input [31:0] addr);
        begin
            @(negedge HCLK);
            HSEL = 1'b1; HTRANS = 2'b10; HWRITE = 1'b1; HADDR = addr;
            @(posedge HCLK); #1;
        end
    endtask

    initial begin
        #12; HRESETn = 1'b1;
        if (HREADY !== 1'b1 || HRESP !== 2'b00) $fatal(1, "AHB idle response");

        address_phase_write(32'h0000_0028); // word 10
        @(negedge HCLK);
        HSEL = 1'b0; HTRANS = 2'b00; HWDATA = 32'h1122_3344;
        byteena = 4'b1111;
        @(posedge HCLK); #1;
        @(negedge HCLK);
        MEM_READ_FROM_CPU = 1'b1; HADDR = 32'h0000_0028;
        HSEL = 1'b1; HTRANS = 2'b10; HWRITE = 1'b0;
        @(posedge HCLK); #1;
        if (HRDATA !== 32'h1122_3344) $fatal(1, "initial AHB write/read");

        MEM_READ_FROM_CPU = 1'b0;
        address_phase_write(32'h0000_0028);
        @(negedge HCLK);
        HSEL = 1'b0; HTRANS = 2'b00; HWDATA = 32'hAABB_CCDD;
        byteena = 4'b0101; BRAM_HAZARD = 1'b1;
        MEM_READ_FROM_CPU = 1'b1; HADDR = 32'h0000_0028;
        HSEL = 1'b1; HTRANS = 2'b10; HWRITE = 1'b0;
        @(posedge HCLK); #1;
        if (dut.ram_q !== 32'h1122_3344)
            $fatal(1, "DMEM collision was not read-first");
        if (HRDATA !== 32'h11BB_33DD)
            $fatal(1, "byte-merged AHB bypass got=%08x", HRDATA);

        @(negedge HCLK);
        BRAM_HAZARD = 1'b0;
        @(posedge HCLK); #1;
        if (HRDATA !== 32'h11BB_33DD)
            $fatal(1, "post-write AHB read got=%08x", HRDATA);
        $display("SUMMARY: PASS AHB memory read-first bypass");
        $finish;
    end
endmodule
