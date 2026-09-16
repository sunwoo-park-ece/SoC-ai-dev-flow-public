`timescale 1ns/1ps
module tb_memory_models;
    reg clock = 1'b0;
    always #5 clock = ~clock;

    reg imem_aclr = 1'b1;
    reg [11:0] imem_address = 12'd0;
    reg imem_clken = 1'b0;
    wire [31:0] imem_q;

    reg [3:0] byteena = 4'd0;
    reg [31:0] data = 32'd0;
    reg [12:0] rdaddress = 13'd0;
    reg rden = 1'b0;
    reg [12:0] wraddress = 13'd0;
    reg wren = 1'b0;
    wire [31:0] dmem_q;

    IMEM #(.INIT_FILE("verification/directed/models/memory/test_image.hex")) u_imem (
        .aclr(imem_aclr), .address(imem_address), .clken(imem_clken),
        .clock(clock), .q(imem_q)
    );

    memory #(.INIT_FILE("verification/directed/models/memory/test_image.hex")) u_dmem (
        .byteena_a(byteena), .clock(clock), .data(data), .rdaddress(rdaddress),
        .rden(rden), .wraddress(wraddress), .wren(wren), .q(dmem_q)
    );

    task expect32(input [31:0] got, input [31:0] expected, input [255:0] label_text);
        begin
            if (got !== expected) begin
                $display("FAIL %0s got=%08x expected=%08x", label_text, got, expected);
                $fatal(1);
            end
        end
    endtask

    task write_word(input [12:0] addr, input [31:0] value, input [3:0] mask);
        begin
            @(negedge clock);
            wraddress = addr; data = value; byteena = mask; wren = 1'b1;
            @(negedge clock);
            wren = 1'b0; byteena = 4'd0;
        end
    endtask

    task read_word(input [12:0] addr, input [31:0] expected);
        begin
            @(negedge clock);
            rdaddress = addr; rden = 1'b1;
            @(posedge clock); #1;
            expect32(dmem_q, expected, "DMEM read");
            @(negedge clock); rden = 1'b0;
        end
    endtask

    initial begin
        #2;
        expect32(imem_q, 32'h0000_0013, "IMEM reset value");
        imem_aclr = 1'b0;
        imem_clken = 1'b1;
        imem_address = 12'd0;
        @(posedge clock); #1;
        expect32(imem_q, 32'h1234_5678, "IMEM image word 0");
        imem_address = 12'd1;
        @(posedge clock); #1;
        expect32(imem_q, 32'h89ab_cdef, "IMEM image word 1");
        imem_clken = 1'b0;
        imem_address = 12'd2;
        @(posedge clock); #1;
        expect32(imem_q, 32'h89ab_cdef, "IMEM clken hold");

        read_word(13'd0, 32'h1234_5678);
        write_word(13'd10, 32'h1122_3344, 4'b1111);
        read_word(13'd10, 32'h1122_3344);
        write_word(13'd10, 32'hAABB_CCDD, 4'b0001);
        read_word(13'd10, 32'h1122_33DD);
        write_word(13'd10, 32'hAABB_CCDD, 4'b0010);
        read_word(13'd10, 32'h1122_CCDD);
        write_word(13'd10, 32'hAABB_CCDD, 4'b0100);
        read_word(13'd10, 32'h11BB_CCDD);
        write_word(13'd10, 32'hAABB_CCDD, 4'b1000);
        read_word(13'd10, 32'hAABB_CCDD);
        write_word(13'd10, 32'h5566_7788, 4'b0101);
        read_word(13'd10, 32'hAA66_CC88);
        write_word(13'd8191, 32'hDEAD_BEEF, 4'b1111);
        read_word(13'd8191, 32'hDEAD_BEEF);

        // Same-edge read/write is explicitly read-first.
        write_word(13'd20, 32'h0102_0304, 4'b1111);
        @(negedge clock);
        rdaddress = 13'd20; rden = 1'b1;
        wraddress = 13'd20; data = 32'hA0B0_C0D0; byteena = 4'b1111; wren = 1'b1;
        @(posedge clock); #1;
        expect32(dmem_q, 32'h0102_0304, "DMEM read-first collision");
        @(negedge clock); wren = 1'b0;
        @(posedge clock); #1;
        expect32(dmem_q, 32'hA0B0_C0D0, "DMEM post-write read");

        rden = 1'b0;
        rdaddress = 13'd0;
        @(posedge clock); #1;
        expect32(dmem_q, 32'hA0B0_C0D0, "DMEM rden hold");
        $display("SUMMARY: PASS memory models");
        $finish;
    end
endmodule
