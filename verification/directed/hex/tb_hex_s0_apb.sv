`timescale 1ns/1ps

// S0 baseline: standalone APB_HEX_display checks only current RTL behavior.
// RAZ/WI and full-offset rejection are intentionally reserved for S1/S2.
module tb_hex_s0_apb;
    localparam logic [31:0] VALUE    = 32'h0000_0000;
    localparam logic [31:0] CTRL     = 32'h0000_0004;
    localparam logic [31:0] RAW_LOW  = 32'h0000_0008;
    localparam logic [31:0] RAW_HIGH = 32'h0000_000c;
    localparam logic [6:0]  BLANK    = 7'b1111111;

    logic clk = 1'b0, resetn = 1'b0, pwrite = 1'b0, psel = 1'b0, penable = 1'b0;
    logic [31:0] paddr = '0, pwdata = '0;
    wire [31:0] prdata;
    wire pready;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;
    integer checks = 0;
    bit inject_bad_expectation;

    always #5 clk = ~clk;

    APB_HEX_display dut (
        .PCLK(clk), .PRESETn(resetn), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(prdata),
        .PREADY(pready), .HEX0(hex0), .HEX1(hex1), .HEX2(hex2),
        .HEX3(hex3), .HEX4(hex4), .HEX5(hex5)
    );

    // Independent copy of the published active-low {g,f,e,d,c,b,a} table.
    function automatic logic [6:0] expected_seg(input logic [3:0] digit);
        case (digit)
            4'h0: expected_seg = 7'b1000000; 4'h1: expected_seg = 7'b1111001;
            4'h2: expected_seg = 7'b0100100; 4'h3: expected_seg = 7'b0110000;
            4'h4: expected_seg = 7'b0011001; 4'h5: expected_seg = 7'b0010010;
            4'h6: expected_seg = 7'b0000010; 4'h7: expected_seg = 7'b1111000;
            4'h8: expected_seg = 7'b0000000; 4'h9: expected_seg = 7'b0010000;
            4'ha: expected_seg = 7'b0001000; 4'hb: expected_seg = 7'b0000011;
            4'hc: expected_seg = 7'b1000110; 4'hd: expected_seg = 7'b0100001;
            4'he: expected_seg = 7'b0000110; 4'hf: expected_seg = 7'b0001110;
            default: expected_seg = BLANK;
        endcase
    endfunction

    task automatic fail(input string message);
        $fatal(1, "S0_CHECK_FAIL: %s", message);
    endtask

    task automatic check_pready(input string where);
        begin
            checks++;
            if (pready !== 1'b1) fail({"PREADY low at ", where});
        end
    endtask

    task automatic expect_read(input logic [31:0] address, input logic [31:0] expected,
                               input string check_id);
        begin
            @(negedge clk);
            paddr = address; psel = 1'b1; penable = 1'b0; pwrite = 1'b0;
            @(posedge clk); // APB SETUP
            @(negedge clk);
            penable = 1'b1;
            #1;
            check_pready(check_id);
            checks++;
            if (prdata !== expected)
                fail($sformatf("%s read addr=%h got=%h expected=%h", check_id, address, prdata, expected));
            @(posedge clk); // Complete ACCESS before dropping selection.
            #1;
            psel = 1'b0; penable = 1'b0; paddr = '0;
        end
    endtask

    task automatic apb_write(input logic [31:0] address, input logic [31:0] data,
                             input string check_id);
        begin
            // SETUP must not commit; ACCESS rising edge is the write commit.
            @(negedge clk);
            paddr = address; pwdata = data; psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            check_pready({check_id, "_setup"});
            @(posedge clk);
            @(negedge clk);
            penable = 1'b1;
            check_pready({check_id, "_access"});
            @(posedge clk);
            #1;
            check_pready({check_id, "_complete"});
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        end
    endtask

    task automatic expect_hex_value(input logic [23:0] value, input string check_id);
        logic [6:0] exp0;
        begin
            exp0 = expected_seg(value[3:0]);
            if (inject_bad_expectation) exp0 = ~exp0; // isolated checker mutation.
            checks++; if (hex0 !== exp0) fail($sformatf("%s HEX0 got=%b expected=%b", check_id, hex0, exp0));
            checks++; if (hex1 !== expected_seg(value[7:4])) fail({check_id, " HEX1 mapping"});
            checks++; if (hex2 !== expected_seg(value[11:8])) fail({check_id, " HEX2 mapping"});
            checks++; if (hex3 !== expected_seg(value[15:12])) fail({check_id, " HEX3 mapping"});
            checks++; if (hex4 !== expected_seg(value[19:16])) fail({check_id, " HEX4 mapping"});
            checks++; if (hex5 !== expected_seg(value[23:20])) fail({check_id, " HEX5 mapping"});
        end
    endtask

    task automatic expect_blank(input string check_id);
        begin
            checks++;
            if ({hex5, hex4, hex3, hex2, hex1, hex0} !== {6{BLANK}})
                fail({check_id, " expected all digits blank"});
        end
    endtask

    initial begin
        inject_bad_expectation = $test$plusargs("INJECT_BAD_EXPECTATION");
        repeat (2) @(posedge clk);
        #1; check_pready("reset");
        resetn = 1'b1;
        repeat (2) @(posedge clk);
        expect_read(CTRL, 32'h0000_0001, "S0_RESET_CTRL");
        expect_read(VALUE, 32'h0000_0000, "S0_RESET_VALUE");
        expect_read(RAW_LOW, 32'h001f_ffff, "S0_RESET_RAW_LOW");
        expect_read(RAW_HIGH, 32'h001f_ffff, "S0_RESET_RAW_HIGH");
        expect_hex_value(24'h000000, "S0_RESET_HEX");

        // Non-ACCESS and unselected writes must not commit.
        @(negedge clk);
        paddr = VALUE; pwdata = 32'h00aa_55aa; psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(VALUE, 32'h0000_0000, "S0_SETUP_NO_WRITE");
        @(negedge clk);
        paddr = VALUE; pwdata = 32'h0055_aa55; psel = 1'b0; penable = 1'b1; pwrite = 1'b1;
        @(posedge clk); #1;
        pwrite = 1'b0; penable = 1'b0; paddr = '0; pwdata = '0;
        expect_read(VALUE, 32'h0000_0000, "S0_UNSELECTED_NO_WRITE");

        // All four canonical registers, documented masks, and decoder mapping.
        apb_write(RAW_LOW, 32'hffe1_2345, "S0_WRITE_RAW_LOW");
        expect_read(RAW_LOW, 32'h0001_2345, "S0_READ_RAW_LOW");
        apb_write(RAW_HIGH, 32'ha001_2345, "S0_WRITE_RAW_HIGH");
        expect_read(RAW_HIGH, 32'h0001_2345, "S0_READ_RAW_HIGH");
        apb_write(CTRL, 32'h0000_0001, "S0_WRITE_CTRL");
        expect_read(CTRL, 32'h0000_0001, "S0_READ_CTRL");
        apb_write(VALUE, 32'hff12_3456, "S0_WRITE_VALUE_123456");
        expect_read(VALUE, 32'h0012_3456, "S0_READ_VALUE_123456");
        expect_hex_value(24'h123456, "S0_MAP_123456");
        apb_write(VALUE, 32'h00ab_cdef, "S0_WRITE_VALUE_ABCDEF");
        expect_read(VALUE, 32'h00ab_cdef, "S0_READ_VALUE_ABCDEF");
        expect_hex_value(24'hab_cdef, "S0_MAP_ABCDEF");
        apb_write(CTRL, 32'h0000_0000, "S0_DISABLE");
        expect_read(CTRL, 32'h0000_0000, "S0_READ_DISABLED_CTRL");
        expect_blank("S0_DISABLE_BLANK");
        apb_write(CTRL, 32'h0000_0001, "S0_REENABLE");
        expect_hex_value(24'hab_cdef, "S0_REENABLE_RESTORES_VALUE");

        if (inject_bad_expectation) fail("INJECT_BAD_EXPECTATION did not reach the HEX checker");
        $display("SUMMARY: PASS HEX S0 checks=%0d", checks);
        $finish;
    end
endmodule
