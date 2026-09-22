`timescale 1ns/1ps

// S2: direct APB-slave proof that only the four exact 16-bit offsets decode.
module tb_hex_s2_exact_decode;
    localparam logic [31:0] VALUE = 32'h0000_0000;
    localparam logic [31:0] CTRL = 32'h0000_0004;
    localparam logic [31:0] RAW_LOW = 32'h0000_0008;
    localparam logic [31:0] RAW_HIGH = 32'h0000_000c;
    localparam logic [6:0] BLANK = 7'b1111111;
    localparam logic [23:0] EXPECT_VALUE = 24'h12_3456;
    localparam logic [20:0] EXPECT_RAW_LOW = 21'h12_3456;
    localparam logic [20:0] EXPECT_RAW_HIGH = 21'h15_4321;

    logic clk = 1'b0, resetn = 1'b0, pwrite = 1'b0, psel = 1'b0, penable = 1'b0;
    logic [31:0] paddr = '0, pwdata = '0;
    wire [31:0] prdata;
    wire pready;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;
    logic [6:0] saved_hex0, saved_hex1, saved_hex2, saved_hex3, saved_hex4, saved_hex5;
    integer checks = 0;
    bit inject_bad_expectation;

    always #5 clk = ~clk;

    APB_HEX_display dut (
        .PCLK(clk), .PRESETn(resetn), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(prdata),
        .PREADY(pready), .HEX0(hex0), .HEX1(hex1), .HEX2(hex2),
        .HEX3(hex3), .HEX4(hex4), .HEX5(hex5)
    );

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
        $fatal(1, "S2_CHECK_FAIL: %s", message);
    endtask

    task automatic check_pready(input string check_id);
        begin
            checks++;
            if (pready !== 1'b1) fail({check_id, " PREADY must be high"});
        end
    endtask

    task automatic apb_write(input logic [31:0] address, input logic [31:0] data,
                             input string check_id);
        begin
            @(negedge clk);
            paddr = address; pwdata = data; psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            @(posedge clk); // SETUP
            @(negedge clk);
            penable = 1'b1;
            check_pready({check_id, "_access"});
            @(posedge clk); // ACCESS commit
            #1;
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        end
    endtask

    task automatic expect_read(input logic [31:0] address, input logic [31:0] expected,
                               input string check_id);
        logic [31:0] oracle;
        begin
            oracle = expected;
            if (inject_bad_expectation && check_id == "S2_MUTATION_TARGET") oracle = oracle ^ 32'h1;
            @(negedge clk);
            paddr = address; psel = 1'b1; penable = 1'b0; pwrite = 1'b0;
            @(posedge clk); // SETUP
            @(negedge clk);
            penable = 1'b1;
            #1;
            check_pready(check_id);
            checks++;
            if (prdata !== oracle)
                fail($sformatf("%s read addr=%h got=%h expected=%h", check_id, address, prdata, oracle));
            @(posedge clk); // ACCESS complete
            #1;
            psel = 1'b0; penable = 1'b0; paddr = '0;
        end
    endtask

    task automatic expect_decoded(input logic [23:0] value, input string check_id);
        begin
            checks++; if (hex0 !== expected_seg(value[3:0])) fail({check_id, " HEX0"});
            checks++; if (hex1 !== expected_seg(value[7:4])) fail({check_id, " HEX1"});
            checks++; if (hex2 !== expected_seg(value[11:8])) fail({check_id, " HEX2"});
            checks++; if (hex3 !== expected_seg(value[15:12])) fail({check_id, " HEX3"});
            checks++; if (hex4 !== expected_seg(value[19:16])) fail({check_id, " HEX4"});
            checks++; if (hex5 !== expected_seg(value[23:20])) fail({check_id, " HEX5"});
        end
    endtask

    task automatic expect_raw(input logic [20:0] low, input logic [20:0] high,
                              input string check_id);
        begin
            checks++; if (hex0 !== low[6:0]) fail({check_id, " HEX0"});
            checks++; if (hex1 !== low[13:7]) fail({check_id, " HEX1"});
            checks++; if (hex2 !== low[20:14]) fail({check_id, " HEX2"});
            checks++; if (hex3 !== high[6:0]) fail({check_id, " HEX3"});
            checks++; if (hex4 !== high[13:7]) fail({check_id, " HEX4"});
            checks++; if (hex5 !== high[20:14]) fail({check_id, " HEX5"});
        end
    endtask

    task automatic capture_hex;
        begin
            saved_hex0 = hex0; saved_hex1 = hex1; saved_hex2 = hex2;
            saved_hex3 = hex3; saved_hex4 = hex4; saved_hex5 = hex5;
        end
    endtask

    task automatic expect_saved_hex(input string check_id);
        begin
            checks++; if (hex0 !== saved_hex0) fail({check_id, " HEX0 changed"});
            checks++; if (hex1 !== saved_hex1) fail({check_id, " HEX1 changed"});
            checks++; if (hex2 !== saved_hex2) fail({check_id, " HEX2 changed"});
            checks++; if (hex3 !== saved_hex3) fail({check_id, " HEX3 changed"});
            checks++; if (hex4 !== saved_hex4) fail({check_id, " HEX4 changed"});
            checks++; if (hex5 !== saved_hex5) fail({check_id, " HEX5 changed"});
        end
    endtask

    task automatic expect_register_state(input string check_id);
        begin
            expect_read(VALUE, {8'h00, EXPECT_VALUE}, {check_id, "_VALUE"});
            expect_read(CTRL, 32'h00000003, {check_id, "_CTRL"});
            expect_read(RAW_LOW, {11'h000, EXPECT_RAW_LOW}, {check_id, "_RAW_LOW"});
            expect_read(RAW_HIGH, {11'h000, EXPECT_RAW_HIGH}, {check_id, "_RAW_HIGH"});
        end
    endtask

    task automatic exercise_invalid(input logic [31:0] address, input string check_id);
        begin
            // Direct slave APB accesses: invalid READ must be zero, then invalid
            // WRITE must leave all external state unchanged.
            expect_read(address, 32'h00000000, {check_id, "_READ_ZERO"});
            apb_write(address, 32'ha5a50000 ^ address, {check_id, "_WRITE_NO_EFFECT"});
            expect_register_state({check_id, "_STATE"});
            expect_saved_hex({check_id, "_HEX"});
        end
    endtask

    initial begin
        inject_bad_expectation = $test$plusargs("INJECT_BAD_EXPECTATION");
        repeat (2) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);
        expect_read(VALUE, 32'h00000000, "S2_RESET_VALUE");
        expect_read(CTRL, 32'h00000001, "S2_RESET_CTRL");
        expect_read(RAW_LOW, 32'h001fffff, "S2_RESET_RAW_LOW");
        expect_read(RAW_HIGH, 32'h001fffff, "S2_RESET_RAW_HIGH");
        expect_decoded(24'h000000, "S2_RESET_DECODED");

        // Canonical offsets must retain their S0/S1 read/write contracts.
        apb_write(VALUE, 32'hab123456, "S2_CANONICAL_VALUE");
        apb_write(CTRL, 32'hffff_ffff, "S2_CANONICAL_CTRL");
        apb_write(RAW_LOW, 32'he0123456, "S2_CANONICAL_RAW_LOW");
        apb_write(RAW_HIGH, 32'hc0154321, "S2_CANONICAL_RAW_HIGH");
        expect_register_state("S2_CANONICAL_READBACK");
        expect_raw(EXPECT_RAW_LOW, EXPECT_RAW_HIGH, "S2_CANONICAL_RAW_OUTPUT");
        capture_hex;

        exercise_invalid(32'h00000010, "S2_MIRROR_10");
        exercise_invalid(32'h00000014, "S2_MIRROR_14");
        exercise_invalid(32'h00000020, "S2_MIRROR_20");
        exercise_invalid(32'h00000001, "S2_MISALIGNED_01");
        exercise_invalid(32'h00000005, "S2_MISALIGNED_05");
        exercise_invalid(32'h0000000d, "S2_BOUNDARY_0D");
        exercise_invalid(32'h0000ffff, "S2_BOUNDARY_FFFF");
        exercise_invalid(32'h00001000, "S2_UPPER_1000");
        exercise_invalid(32'h00008004, "S2_UPPER_8004");

        // Isolated checker mutation must fail despite a correct canonical read.
        expect_read(VALUE, {8'h00, EXPECT_VALUE}, "S2_MUTATION_TARGET");
        if (inject_bad_expectation) fail("INJECT_BAD_EXPECTATION did not reach S2 checker");
        $display("SUMMARY: PASS HEX S2 exact-decode checks=%0d", checks);
        $finish;
    end
endmodule
