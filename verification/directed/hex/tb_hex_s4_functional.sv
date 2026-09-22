`timescale 1ns/1ps

// S4: HEX-002 Directed Functional Verification.
// DUT stimulus via APB ports only.  Independent oracle; DUT internals not used.
//
// Mutation control:
//   +INJECT_BAD_EXPECTATION  -- corrupts oracle for digit 0 (Mutation A)
//   +INJECT_RAW_MAP_FAULT    -- run with mut_raw DUT (B)
//   +INJECT_DEC_FAULT        -- run with mut_dec DUT (C)
module tb_hex_s4_functional;

    localparam logic [31:0] VALUE    = 32'h0000_0000;
    localparam logic [31:0] CTRL     = 32'h0000_0004;
    localparam logic [31:0] RAW_LOW  = 32'h0000_0008;
    localparam logic [31:0] RAW_HIGH = 32'h0000_000c;
    localparam logic [6:0]  BLANK    = 7'b1111111;
    localparam logic [6:0]  ALL_ON   = 7'b0000000;

    logic        clk     = 1'b0;
    logic        resetn  = 1'b0;
    logic        pwrite  = 1'b0;
    logic        psel    = 1'b0;
    logic        penable = 1'b0;
    logic [31:0] paddr   = '0;
    logic [31:0] pwdata  = '0;
    wire  [31:0] prdata;
    wire         pready;
    wire  [6:0]  hex0, hex1, hex2, hex3, hex4, hex5;

    integer checks = 0;
    bit     inject_bad_expectation;

    // Module-scope loop variables (iverilog 11: no loop-variable declarations)
    integer di, bi, digit_i;
    logic [23:0] val24;
    logic [20:0] low_pat, high_pat, raw_l, raw_h, old_l, old_h, new_l, new_h;
    logic [6:0]  expected_seg;
    logic [31:0] saved_v, saved_c, saved_sl, saved_sh;

    always #5 clk = ~clk;

    APB_HEX_display dut (
        .PCLK(clk), .PRESETn(resetn),
        .PADDR(paddr), .PWRITE(pwrite), .PSEL(psel), .PENABLE(penable),
        .PWDATA(pwdata), .PRDATA(prdata), .PREADY(pready),
        .HEX0(hex0), .HEX1(hex1), .HEX2(hex2),
        .HEX3(hex3), .HEX4(hex4), .HEX5(hex5)
    );

    // -----------------------------------------------------------------------
    // Independent Decoder Table — SPEC {g,f,e,d,c,b,a} active-low
    // Mutation A: inject_bad_expectation corrupts digit 0.
    // -----------------------------------------------------------------------
    function automatic logic [6:0] dec_oracle(input logic [3:0] digit);
        case (digit)
            4'h0: dec_oracle = inject_bad_expectation ? ~7'b1000000 : 7'b1000000;
            4'h1: dec_oracle = 7'b1111001;
            4'h2: dec_oracle = 7'b0100100;
            4'h3: dec_oracle = 7'b0110000;
            4'h4: dec_oracle = 7'b0011001;
            4'h5: dec_oracle = 7'b0010010;
            4'h6: dec_oracle = 7'b0000010;
            4'h7: dec_oracle = 7'b1111000;
            4'h8: dec_oracle = 7'b0000000;
            4'h9: dec_oracle = 7'b0010000;
            4'ha: dec_oracle = 7'b0001000;
            4'hb: dec_oracle = 7'b0000011;
            4'hc: dec_oracle = 7'b1000110;
            4'hd: dec_oracle = 7'b0100001;
            4'he: dec_oracle = 7'b0000110;
            4'hf: dec_oracle = 7'b0001110;
            default: dec_oracle = BLANK;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // APB helpers — old-style task port syntax for iverilog 11
    // -----------------------------------------------------------------------
    task automatic apb_write(input logic [31:0] address, input logic [31:0] data,
                             input string check_id);
        begin
            @(negedge clk);
            paddr = address; pwdata = data;
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            @(posedge clk); // SETUP — no commit
            @(negedge clk);
            penable = 1'b1;
            checks++;
            if (pready !== 1'b1) $fatal(1, "S4_CHECK_FAIL: %s — PREADY=0 in ACCESS", check_id);
            @(posedge clk); // ACCESS — commit
            #1;
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
            paddr = '0; pwdata = '0;
        end
    endtask

    task automatic apb_read(input logic [31:0] address, output logic [31:0] rdata,
                            input string check_id);
        begin
            @(negedge clk);
            paddr = address; psel = 1'b1; penable = 1'b0; pwrite = 1'b0;
            @(posedge clk); // SETUP
            @(negedge clk);
            penable = 1'b1;
            #1;
            checks++;
            if (pready !== 1'b1) $fatal(1, "S4_CHECK_FAIL: %s — PREADY=0 in READ", check_id);
            rdata = prdata;
            @(posedge clk);
            #1;
            psel = 1'b0; penable = 1'b0; paddr = '0;
        end
    endtask

    task automatic expect_read(input logic [31:0] address, input logic [31:0] expected,
                               input string check_id);
        logic [31:0] got;
        begin
            apb_read(address, got, check_id);
            checks++;
            if (got !== expected)
                $fatal(1, "S4_CHECK_FAIL: %s — addr=%h got=%h exp=%h", check_id, address, got, expected);
        end
    endtask

    // -----------------------------------------------------------------------
    // Output checkers
    // -----------------------------------------------------------------------
    task automatic expect_decoded(input logic [23:0] value, input string check_id);
        begin
            checks++;
            if (hex0 !== dec_oracle(value[3:0]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX0 — got=%b exp=%b", check_id, hex0, dec_oracle(value[3:0]));
            checks++;
            if (hex1 !== dec_oracle(value[7:4]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX1 — got=%b exp=%b", check_id, hex1, dec_oracle(value[7:4]));
            checks++;
            if (hex2 !== dec_oracle(value[11:8]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX2 — got=%b exp=%b", check_id, hex2, dec_oracle(value[11:8]));
            checks++;
            if (hex3 !== dec_oracle(value[15:12]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX3 — got=%b exp=%b", check_id, hex3, dec_oracle(value[15:12]));
            checks++;
            if (hex4 !== dec_oracle(value[19:16]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX4 — got=%b exp=%b", check_id, hex4, dec_oracle(value[19:16]));
            checks++;
            if (hex5 !== dec_oracle(value[23:20]))
                $fatal(1, "S4_CHECK_FAIL: %s_HEX5 — got=%b exp=%b", check_id, hex5, dec_oracle(value[23:20]));
        end
    endtask

    task automatic expect_raw(input logic [20:0] low, input logic [20:0] high,
                              input string check_id);
        begin
            checks++;
            if (hex0 !== low[6:0])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX0 — got=%b exp=%b", check_id, hex0, low[6:0]);
            checks++;
            if (hex1 !== low[13:7])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX1 — got=%b exp=%b", check_id, hex1, low[13:7]);
            checks++;
            if (hex2 !== low[20:14])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX2 — got=%b exp=%b", check_id, hex2, low[20:14]);
            checks++;
            if (hex3 !== high[6:0])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX3 — got=%b exp=%b", check_id, hex3, high[6:0]);
            checks++;
            if (hex4 !== high[13:7])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX4 — got=%b exp=%b", check_id, hex4, high[13:7]);
            checks++;
            if (hex5 !== high[20:14])
                $fatal(1, "S4_CHECK_FAIL: %s_HEX5 — got=%b exp=%b", check_id, hex5, high[20:14]);
        end
    endtask

    task automatic expect_blank(input string check_id);
        begin
            checks++;
            if ({hex5,hex4,hex3,hex2,hex1,hex0} !== {6{BLANK}})
                $fatal(1, "S4_CHECK_FAIL: %s — not all blank: %b%b%b%b%b%b",
                       check_id, hex5,hex4,hex3,hex2,hex1,hex0);
        end
    endtask

    task automatic do_reset;
        begin
            @(negedge clk); resetn = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            resetn = 1'b1;
            @(posedge clk); #1;
            @(posedge clk); #1;
        end
    endtask

    task automatic check_reset_state(input string pfx);
        begin
            expect_read(VALUE,    32'h0000_0000, {pfx,"_VALUE"});
            expect_read(CTRL,     32'h0000_0001, {pfx,"_CTRL"});
            expect_read(RAW_LOW,  32'h001f_ffff, {pfx,"_RAW_LOW"});
            expect_read(RAW_HIGH, 32'h001f_ffff, {pfx,"_RAW_HIGH"});
            expect_decoded(24'h000000, {pfx,"_HEX"});
        end
    endtask

    // ========================================================================
    // MAIN
    // ========================================================================
    initial begin
        inject_bad_expectation = $test$plusargs("INJECT_BAD_EXPECTATION");

        // Power-on reset
        repeat (2) @(posedge clk);
        #1; resetn = 1'b1;
        repeat (2) @(posedge clk);

        // -------------------------------------------------------------------
        // D09 pre: PSEL=0 write must be ignored
        // -------------------------------------------------------------------
        @(negedge clk);
        paddr = VALUE; pwdata = 32'hDEADBEEF;
        psel = 1'b0; penable = 1'b1; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(VALUE, 32'h0000_0000, "D09_PSEL0_NO_WRITE");

        // D09: SETUP-only (PENABLE=0) must not commit
        @(negedge clk);
        paddr = VALUE; pwdata = 32'hDEADBEEF;
        psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(VALUE, 32'h0000_0000, "D09_SETUP_NO_COMMIT");

        check_reset_state("D09_RESET_STATE");

        // -------------------------------------------------------------------
        // D01: Decoder — 16 digits × 6 positions
        // -------------------------------------------------------------------
        apb_write(CTRL, 32'h0000_0001, "D01_DEC_MODE");
        for (di = 0; di < 6; di = di + 1) begin
            for (digit_i = 0; digit_i <= 15; digit_i = digit_i + 1) begin
                // contrast fill: target position = digit_i, others = ~digit_i
                val24 = {6{~digit_i[3:0]}};
                val24[di*4 +: 4] = digit_i[3:0];
                apb_write(VALUE, {8'h00, val24}, "D01_LOOP");
                checks++;
                if (hex0 !== dec_oracle(val24[3:0]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX0 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex0, dec_oracle(val24[3:0]));
                checks++;
                if (hex1 !== dec_oracle(val24[7:4]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX1 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex1, dec_oracle(val24[7:4]));
                checks++;
                if (hex2 !== dec_oracle(val24[11:8]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX2 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex2, dec_oracle(val24[11:8]));
                checks++;
                if (hex3 !== dec_oracle(val24[15:12]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX3 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex3, dec_oracle(val24[15:12]));
                checks++;
                if (hex4 !== dec_oracle(val24[19:16]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX4 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex4, dec_oracle(val24[19:16]));
                checks++;
                if (hex5 !== dec_oracle(val24[23:20]))
                    $fatal(1, "S4_CHECK_FAIL: D01_HEX5 — di=%0d dig=%0d got=%b exp=%b",
                           di, digit_i, hex5, dec_oracle(val24[23:20]));
            end
        end
        // All-different pattern
        apb_write(VALUE, 32'h00AB_CDEF, "D01_ABCDEF_WR");
        expect_decoded(24'hABCDEF, "D01_ABCDEF");
        // VALUE[31:24] masking
        apb_write(VALUE, 32'hFF_ABCDEF, "D01_UPPER_BYTE_WR");
        expect_decoded(24'hABCDEF, "D01_UPPER_BYTE_NO_EFFECT");
        expect_read(VALUE, 32'h00ABCDEF, "D01_UPPER_BYTE_READBACK");

        // -------------------------------------------------------------------
        // D03: Active-low / Blank / All-on
        // -------------------------------------------------------------------
        apb_write(VALUE, 32'h0000_0000, "D03_VALUE_0");
        checks++;
        if (hex0 !== 7'b1000000)
            $fatal(1, "S4_CHECK_FAIL: D03_HEX0_PATTERN — exp=7'b1000000 got=%b", hex0);
        apb_write(CTRL, 32'h0000_0000, "D03_DISABLE");
        expect_blank("D03_BLANK");
        apb_write(CTRL, 32'h0000_0001, "D03_REENABLE");
        // RAW mode: All-on per digit
        apb_write(CTRL, 32'h0000_0003, "D03_RAW_MODE_ON");
        for (di = 0; di < 6; di = di + 1) begin
            low_pat  = 21'h1fffff;
            high_pat = 21'h1fffff;
            if (di < 3)
                low_pat[di*7 +: 7] = 7'b0000000;
            else
                high_pat[(di-3)*7 +: 7] = 7'b0000000;
            apb_write(RAW_LOW,  {11'h000, low_pat},  "D03_ALL_ON_LOW");
            apb_write(RAW_HIGH, {11'h000, high_pat}, "D03_ALL_ON_HIGH");
            checks++;
            if (hex0 !== low_pat[6:0])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX0 — di=%0d got=%b exp=%b", di, hex0, low_pat[6:0]);
            checks++;
            if (hex1 !== low_pat[13:7])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX1 — di=%0d got=%b exp=%b", di, hex1, low_pat[13:7]);
            checks++;
            if (hex2 !== low_pat[20:14])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX2 — di=%0d got=%b exp=%b", di, hex2, low_pat[20:14]);
            checks++;
            if (hex3 !== high_pat[6:0])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX3 — di=%0d got=%b exp=%b", di, hex3, high_pat[6:0]);
            checks++;
            if (hex4 !== high_pat[13:7])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX4 — di=%0d got=%b exp=%b", di, hex4, high_pat[13:7]);
            checks++;
            if (hex5 !== high_pat[20:14])
                $fatal(1, "S4_CHECK_FAIL: D03_ALL_ON_HEX5 — di=%0d got=%b exp=%b", di, hex5, high_pat[20:14]);
        end

        // -------------------------------------------------------------------
        // D02: RAW Six-field packing — distinct patterns + Walking-zero/one
        // -------------------------------------------------------------------
        // Six distinct patterns
        low_pat  = {7'b1100110, 7'b0101010, 7'b1010101}; // HEX2,HEX1,HEX0
        high_pat = {7'b0001111, 7'b1110000, 7'b0011001}; // HEX5,HEX4,HEX3
        apb_write(CTRL,     32'h0000_0003,          "D02_RAW_ENABLE");
        apb_write(RAW_LOW,  {11'h000, low_pat},     "D02_RAW_LOW_DISTINCT");
        apb_write(RAW_HIGH, {11'h000, high_pat},    "D02_RAW_HIGH_DISTINCT");
        expect_raw(low_pat, high_pat, "D02_DISTINCT_MAPPING");
        expect_read(RAW_LOW,  {11'h000, low_pat},  "D02_READBACK_LOW");
        expect_read(RAW_HIGH, {11'h000, high_pat}, "D02_READBACK_HIGH");

        // Walking-zero: each digit, each bit
        for (di = 0; di < 6; di = di + 1) begin
            for (bi = 0; bi < 7; bi = bi + 1) begin
                low_pat      = 21'h1fffff;
                high_pat     = 21'h1fffff;
                expected_seg = 7'b1111111;
                expected_seg[bi] = 1'b0;
                if (di < 3)
                    low_pat[di*7 + bi] = 1'b0;
                else
                    high_pat[(di-3)*7 + bi] = 1'b0;
                apb_write(RAW_LOW,  {11'h000, low_pat},  "D02_WLKZ_LOW");
                apb_write(RAW_HIGH, {11'h000, high_pat}, "D02_WLKZ_HIGH");
                // Target digit check
                checks++;
                case (di)
                    0: if (hex0 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX0 — bi=%0d got=%b exp=%b", bi, hex0, expected_seg);
                    1: if (hex1 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX1 — bi=%0d got=%b exp=%b", bi, hex1, expected_seg);
                    2: if (hex2 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX2 — bi=%0d got=%b exp=%b", bi, hex2, expected_seg);
                    3: if (hex3 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX3 — bi=%0d got=%b exp=%b", bi, hex3, expected_seg);
                    4: if (hex4 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX4 — bi=%0d got=%b exp=%b", bi, hex4, expected_seg);
                    5: if (hex5 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_HEX5 — bi=%0d got=%b exp=%b", bi, hex5, expected_seg);
                    default: ;
                endcase
                // Other digits must be BLANK
                checks++; if (di != 0 && hex0 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX0 — di=%0d bi=%0d hex0=%b", di, bi, hex0);
                checks++; if (di != 1 && hex1 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX1 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 2 && hex2 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX2 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 3 && hex3 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX3 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 4 && hex4 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX4 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 5 && hex5 !== BLANK) $fatal(1, "S4_CHECK_FAIL: D02_WLKZ_OTHERS_HEX5 — di=%0d bi=%0d", di, bi);
            end
        end

        // Walking-one: each digit, each bit
        for (di = 0; di < 6; di = di + 1) begin
            for (bi = 0; bi < 7; bi = bi + 1) begin
                low_pat      = 21'h000000;
                high_pat     = 21'h000000;
                expected_seg = 7'b0000000;
                expected_seg[bi] = 1'b1;
                if (di < 3)
                    low_pat[di*7 + bi] = 1'b1;
                else
                    high_pat[(di-3)*7 + bi] = 1'b1;
                apb_write(RAW_LOW,  {11'h000, low_pat},  "D02_WLKO_LOW");
                apb_write(RAW_HIGH, {11'h000, high_pat}, "D02_WLKO_HIGH");
                checks++;
                case (di)
                    0: if (hex0 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX0 — bi=%0d got=%b exp=%b", bi, hex0, expected_seg);
                    1: if (hex1 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX1 — bi=%0d got=%b exp=%b", bi, hex1, expected_seg);
                    2: if (hex2 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX2 — bi=%0d got=%b exp=%b", bi, hex2, expected_seg);
                    3: if (hex3 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX3 — bi=%0d got=%b exp=%b", bi, hex3, expected_seg);
                    4: if (hex4 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX4 — bi=%0d got=%b exp=%b", bi, hex4, expected_seg);
                    5: if (hex5 !== expected_seg) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_HEX5 — bi=%0d got=%b exp=%b", bi, hex5, expected_seg);
                    default: ;
                endcase
                checks++; if (di != 0 && hex0 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX0 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 1 && hex1 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX1 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 2 && hex2 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX2 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 3 && hex3 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX3 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 4 && hex4 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX4 — di=%0d bi=%0d", di, bi);
                checks++; if (di != 5 && hex5 !== ALL_ON) $fatal(1, "S4_CHECK_FAIL: D02_WLKO_OTHERS_HEX5 — di=%0d bi=%0d", di, bi);
            end
        end

        // -------------------------------------------------------------------
        // D04: RAW High-bit Masking
        // -------------------------------------------------------------------
        begin : D04
            logic [20:0] d04_vl, d04_vh;
            d04_vl = 21'h15_5555;
            d04_vh = 21'h0a_aaaa;
            apb_write(CTRL,     32'h0000_0003,                      "D04_CTL_RAW");
            apb_write(RAW_LOW,  {11'h7ff, d04_vl},                  "D04_RAW_LOW_UPPER_WR");
            apb_write(RAW_HIGH, {11'h7ff, d04_vh},                  "D04_RAW_HIGH_UPPER_WR");
            expect_read(RAW_LOW,  {11'h000, d04_vl}, "D04_RAW_LOW_READBACK");
            expect_read(RAW_HIGH, {11'h000, d04_vh}, "D04_RAW_HIGH_READBACK");
            expect_raw(d04_vl, d04_vh, "D04_OUTPUT");
            // Same lower 21 bits, different upper → output unchanged
            apb_write(RAW_LOW,  {11'h555, d04_vl}, "D04_RAW_LOW_UPPER_ONLY");
            apb_write(RAW_HIGH, {11'h2aa, d04_vh}, "D04_RAW_HIGH_UPPER_ONLY");
            expect_raw(d04_vl, d04_vh, "D04_UPPER_ONLY_OUTPUT_UNCHANGED");
            // VALUE [31:24] masking
            apb_write(CTRL, 32'h0000_0001, "D04_BACK_TO_DEC");
            apb_write(VALUE, 32'hAA_123456, "D04_VALUE_UPPER_WR");
            expect_read(VALUE, 32'h00_123456, "D04_VALUE_UPPER_READBACK");
            // CTRL [31:2] masking
            apb_write(CTRL, 32'hFFFF_FFFD, "D04_CTRL_RESERVED_WR");
            expect_read(CTRL, 32'h0000_0001, "D04_CTRL_RESERVED_READBACK");
        end

        // -------------------------------------------------------------------
        // D05: Decoder ↔ RAW Mode Switching
        // -------------------------------------------------------------------
        raw_l = 21'h15_5555;
        raw_h = 21'h0a_aaaa;
        apb_write(CTRL,     32'h0000_0001,    "D05_DEC_MODE");
        apb_write(VALUE,    32'h00_ABCDEF,    "D05_VALUE_ABCDEF");
        apb_write(RAW_LOW,  {11'h000, raw_l}, "D05_RAW_LOW_PRESET");
        apb_write(RAW_HIGH, {11'h000, raw_h}, "D05_RAW_HIGH_PRESET");
        // Step 1
        expect_decoded(24'hABCDEF, "D05_STEP1_DEC_OUT");
        // Step 2
        apb_write(CTRL, 32'h0000_0003, "D05_STEP2_RAW_ENTER");
        expect_raw(raw_l, raw_h, "D05_STEP2_RAW_OUT");
        // Step 3: VALUE change in RAW → output unchanged
        apb_write(VALUE, 32'h00_123456, "D05_STEP3_VALUE_CHANGE");
        expect_raw(raw_l, raw_h, "D05_STEP3_OUT_UNCHANGED");
        // Step 4: Return to decoder → new VALUE
        apb_write(CTRL, 32'h0000_0001, "D05_STEP4_DEC_RETURN");
        expect_decoded(24'h123456, "D05_STEP4_NEW_VALUE");
        // Step 5: RAW change in decoder → decoder output unchanged
        raw_l = 21'h06_DB6D;
        raw_h = 21'h13_6DB6;
        apb_write(RAW_LOW,  {11'h000, raw_l}, "D05_STEP5_RAW_LOW_CHANGE");
        apb_write(RAW_HIGH, {11'h000, raw_h}, "D05_STEP5_RAW_HIGH_CHANGE");
        expect_decoded(24'h123456, "D05_STEP5_DEC_UNCHANGED");
        // Step 6: Re-enter RAW → new RAW
        apb_write(CTRL, 32'h0000_0003, "D05_STEP6_RAW_REENTER");
        expect_raw(raw_l, raw_h, "D05_STEP6_NEW_RAW_OUT");
        // Readback confirms no corruption
        expect_read(VALUE,    32'h00_123456,    "D05_VALUE_READBACK");
        expect_read(RAW_LOW,  {11'h000, raw_l}, "D05_RAW_LOW_READBACK");
        expect_read(RAW_HIGH, {11'h000, raw_h}, "D05_RAW_HIGH_READBACK");

        // -------------------------------------------------------------------
        // D06: ENABLE Disable / Restore
        // -------------------------------------------------------------------
        apb_write(CTRL,  32'h0000_0001, "D06_DEC_ENABLE");
        apb_write(VALUE, 32'h00_FEDCBA, "D06_DEC_VALUE");
        expect_decoded(24'hFEDCBA, "D06_DEC_CONFIRM");
        apb_write(CTRL, 32'h0000_0000, "D06_DISABLE");
        expect_blank("D06_DISABLED_BLANK");
        apb_write(VALUE, 32'h00_135790, "D06_DISABLED_VALUE_CHANGE");
        expect_blank("D06_STILL_BLANK_AFTER_VALUE");
        apb_write(RAW_LOW,  32'h00_155555, "D06_RAW_LOW_SET");
        apb_write(RAW_HIGH, 32'h00_0AAAAA, "D06_RAW_HIGH_SET");
        apb_write(CTRL, 32'h0000_0002, "D06_DISABLED_RAW_MODE"); // ENABLE=0, RAW=1
        expect_blank("D06_STILL_BLANK_RAW_MODE_DISABLED");
        expect_read(VALUE,    32'h00_135790, "D06_READBACK_VALUE");
        expect_read(CTRL,     32'h0000_0002, "D06_READBACK_CTRL");
        expect_read(RAW_LOW,  32'h00_155555, "D06_READBACK_RAW_LOW");
        expect_read(RAW_HIGH, 32'h00_0AAAAA, "D06_READBACK_RAW_HIGH");
        apb_write(CTRL, 32'h0000_0003, "D06_REENABLE_RAW");
        expect_raw(21'h155555, 21'h0AAAAA, "D06_REENABLE_RAW_OUT");
        apb_write(CTRL, 32'h0000_0001, "D06_SWITCH_DEC");
        expect_decoded(24'h135790, "D06_DEC_AFTER_REENABLE");

        // -------------------------------------------------------------------
        // D07: Reset During Active Operation
        // -------------------------------------------------------------------
        // Case 1: Decoder active
        apb_write(CTRL,  32'h0000_0001, "D07_C1_DEC");
        apb_write(VALUE, 32'h00_ABCDEF, "D07_C1_VALUE");
        expect_decoded(24'hABCDEF, "D07_C1_BEFORE");
        do_reset;
        check_reset_state("D07_C1");
        // Case 2: RAW active
        apb_write(CTRL,     32'h0000_0003, "D07_C2_RAW");
        apb_write(RAW_LOW,  32'h00_155555, "D07_C2_RAW_LOW");
        apb_write(RAW_HIGH, 32'h00_0AAAAA, "D07_C2_RAW_HIGH");
        expect_raw(21'h155555, 21'h0AAAAA, "D07_C2_BEFORE");
        do_reset;
        check_reset_state("D07_C2");
        // Case 3: ENABLE=0
        apb_write(CTRL, 32'h0000_0000, "D07_C3_DISABLE");
        apb_write(VALUE, 32'h00_123456, "D07_C3_VALUE");
        expect_blank("D07_C3_BEFORE");
        do_reset;
        check_reset_state("D07_C3");
        // Confirm reset is NOT blank (ENABLE=1 after reset)
        checks++;
        if ({hex5,hex4,hex3,hex2,hex1,hex0} === {6{BLANK}})
            $fatal(1, "S4_CHECK_FAIL: D07_NOT_BLANK — reset must show Hex-0 (ENABLE=1), not blank");

        // -------------------------------------------------------------------
        // D08: RAW Non-atomic Update
        // -------------------------------------------------------------------
        old_l = 21'h155555;
        old_h = 21'h0AAAAA;
        new_l = 21'h06DB6D;
        new_h = 21'h136DB6;
        apb_write(CTRL,     32'h0000_0003,    "D08_RAW_ENABLE");
        apb_write(RAW_LOW,  {11'h000, old_l}, "D08_OLD_RAW_LOW");
        apb_write(RAW_HIGH, {11'h000, old_h}, "D08_OLD_RAW_HIGH");
        expect_raw(old_l, old_h, "D08_START");
        // Update LOW only
        apb_write(RAW_LOW, {11'h000, new_l}, "D08_NEW_RAW_LOW_ONLY");
        checks++; if (hex0 !== new_l[6:0])   $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX0 — got=%b exp=%b", hex0, new_l[6:0]);
        checks++; if (hex1 !== new_l[13:7])  $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX1 — got=%b exp=%b", hex1, new_l[13:7]);
        checks++; if (hex2 !== new_l[20:14]) $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX2 — got=%b exp=%b", hex2, new_l[20:14]);
        checks++; if (hex3 !== old_h[6:0])   $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX3 — got=%b exp=%b", hex3, old_h[6:0]);
        checks++; if (hex4 !== old_h[13:7])  $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX4 — got=%b exp=%b", hex4, old_h[13:7]);
        checks++; if (hex5 !== old_h[20:14]) $fatal(1, "S4_CHECK_FAIL: D08_MIX_HEX5 — got=%b exp=%b", hex5, old_h[20:14]);
        apb_write(RAW_HIGH, {11'h000, new_h}, "D08_NEW_RAW_HIGH");
        expect_raw(new_l, new_h, "D08_COMPLETE");
        // Reverse: HIGH first
        apb_write(RAW_LOW,  {11'h000, old_l}, "D08_RESET_LOW");
        apb_write(RAW_HIGH, {11'h000, old_h}, "D08_RESET_HIGH");
        apb_write(RAW_HIGH, {11'h000, new_h}, "D08_REV_HIGH_FIRST");
        checks++; if (hex0 !== old_l[6:0])   $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX0 — got=%b exp=%b", hex0, old_l[6:0]);
        checks++; if (hex1 !== old_l[13:7])  $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX1 — got=%b exp=%b", hex1, old_l[13:7]);
        checks++; if (hex2 !== old_l[20:14]) $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX2 — got=%b exp=%b", hex2, old_l[20:14]);
        checks++; if (hex3 !== new_h[6:0])   $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX3 — got=%b exp=%b", hex3, new_h[6:0]);
        checks++; if (hex4 !== new_h[13:7])  $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX4 — got=%b exp=%b", hex4, new_h[13:7]);
        checks++; if (hex5 !== new_h[20:14]) $fatal(1, "S4_CHECK_FAIL: D08_REV_MIX_HEX5 — got=%b exp=%b", hex5, new_h[20:14]);
        apb_write(RAW_LOW, {11'h000, new_l}, "D08_REV_LOW_SECOND");
        expect_raw(new_l, new_h, "D08_REV_COMPLETE");
        // SW idiom: disable-update-enable
        apb_write(CTRL, 32'h0000_0002, "D08_SW_DISABLE");
        expect_blank("D08_SW_DISABLED");
        apb_write(RAW_LOW,  {11'h000, old_l}, "D08_SW_UPDATE_LOW");
        apb_write(RAW_HIGH, {11'h000, old_h}, "D08_SW_UPDATE_HIGH");
        expect_blank("D08_SW_STILL_BLANK");
        apb_write(CTRL, 32'h0000_0003, "D08_SW_REENABLE");
        expect_raw(old_l, old_h, "D08_SW_RESTORED");

        // -------------------------------------------------------------------
        // D09: SETUP no-commit per register
        // -------------------------------------------------------------------
        apb_read(VALUE,    saved_v,  "D09_SAVE_VALUE");
        apb_read(CTRL,     saved_c,  "D09_SAVE_CTRL");
        apb_read(RAW_LOW,  saved_sl, "D09_SAVE_RAW_LOW");
        apb_read(RAW_HIGH, saved_sh, "D09_SAVE_RAW_HIGH");
        @(negedge clk);
        paddr = VALUE; pwdata = 32'hDEAD_BEEF;
        psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(VALUE, saved_v, "D09_VALUE_SETUP_NO_COMMIT");
        @(negedge clk);
        paddr = CTRL; pwdata = 32'hDEAD_BEEF;
        psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(CTRL, saved_c, "D09_CTRL_SETUP_NO_COMMIT");
        @(negedge clk);
        paddr = RAW_LOW; pwdata = 32'hDEAD_BEEF;
        psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(RAW_LOW, saved_sl, "D09_RAW_LOW_SETUP_NO_COMMIT");
        @(negedge clk);
        paddr = RAW_HIGH; pwdata = 32'hDEAD_BEEF;
        psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
        @(posedge clk); #1;
        psel = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
        expect_read(RAW_HIGH, saved_sh, "D09_RAW_HIGH_SETUP_NO_COMMIT");

        // -------------------------------------------------------------------
        // Injection guard
        // -------------------------------------------------------------------
        if (inject_bad_expectation)
            $fatal(1, "S4_CHECK_FAIL: D01_INJECT_NOT_TRIGGERED — plusarg set but digit-0 not reached");

        $display("SUMMARY: PASS HEX S4 functional checks=%0d", checks);
        $finish;
    end

endmodule
