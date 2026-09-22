`timescale 1ns/1ps
module tb_hex_s5_bridge;
    reg HCLK = 0, HRESETn = 0;
    reg [31:0] HADDR = 0, HWDATA = 0, PRDATA = 32'h0;
    reg HWRITE = 0, HSEL = 0, PREADY = 1, PSLVERR = 0;
    reg [1:0] HTRANS = 0;
    reg [2:0] HSIZE = 3'b010;
    wire [31:0] HRDATA, PADDR, PWDATA;
    wire HREADY, PCLK, PRESETn, PWRITE, PENABLE;
    wire [1:0] HRESP;
    wire [15:0] PSEL;
    wire HREADY_IN = HREADY;

    integer checks = 0;

    always #5 HCLK = ~HCLK;

    AHB_APB_bridge dut (.*);

    task check_step(input string step_name);
        begin
            checks = checks + 1;
        end
    endtask

    task issue(input [31:0] addr, input wr, input [2:0] size, input [31:0] data);
        begin
            @(negedge HCLK);
            HADDR = addr; HWRITE = wr; HSIZE = size; HWDATA = data;
            HSEL = 1; HTRANS = 2'b10;
            @(posedge HCLK); #1;
            if (PADDR !== addr || HREADY !== 0 || PENABLE !== 0)
                $fatal(1, "L1_SETUP_FAIL: PADDR/HREADY/PENABLE mismatch for addr=%h (got PADDR=%h, HREADY=%b, PENABLE=%b)",
                       addr, PADDR, HREADY, PENABLE);
            @(negedge HCLK);
            HSEL = 0; HTRANS = 0;
        end
    endtask

    task expect_ok(input [15:0] select, input [31:0] exp_rdata);
        begin
            PRDATA = exp_rdata;
            if (PSEL !== select || PWDATA !== HWDATA)
                $fatal(1, "L1_OK_SETUP_FAIL: got PSEL=%h PWDATA=%h, exp PSEL=%h PWDATA=%h",
                       PSEL, PWDATA, select, HWDATA);
            @(posedge HCLK); #1;
            if (PSEL !== select || PENABLE !== 1 || PADDR !== HADDR ||
                (PWRITE && PWDATA !== HWDATA) || HRESP !== 2'b00 || HREADY !== PREADY)
                $fatal(1, "L1_OK_ACCESS_FAIL: select=%h got PSEL=%h PENABLE=%b PADDR=%h PWDATA=%h HRESP=%b HREADY=%b",
                       select, PSEL, PENABLE, PADDR, PWDATA, HRESP, HREADY);
            if (!PWRITE && HRDATA !== exp_rdata)
                $fatal(1, "L1_OK_RDATA_FAIL: got HRDATA=%h, exp PRDATA=%h", HRDATA, exp_rdata);
            @(posedge HCLK); #1;
            if (PSEL !== 0 || HRESP !== 2'b00 || HREADY !== 1)
                $fatal(1, "L1_OK_RETIRE_FAIL: valid transfer did not retire clean");
            check_step("EXPECT_OK");
        end
    endtask

    task expect_error(input string check_id);
        begin
            if (PSEL !== 16'h0000)
                $fatal(1, "L1_SUPPRESSION_FAIL: %s — invalid request asserted PSEL=%h (expected 0)", check_id, PSEL);
            @(posedge HCLK); #1;
            if (PSEL !== 16'h0000 || PENABLE !== 1 || HRESP !== 2'b01 || HREADY !== 0)
                $fatal(1, "L1_ERR_CYC1_FAIL: %s — cycle 1 ERROR missing (PSEL=%h, PENABLE=%b, HRESP=%b, HREADY=%b)",
                       check_id, PSEL, PENABLE, HRESP, HREADY);
            @(posedge HCLK); #1;
            if (PSEL !== 16'h0000 || HRESP !== 2'b01 || HREADY !== 1)
                $fatal(1, "L1_ERR_CYC2_FAIL: %s — cycle 2 ERROR missing (PSEL=%h, HRESP=%b, HREADY=%b)",
                       check_id, PSEL, HRESP, HREADY);
            @(posedge HCLK); #1;
            if (HRESP !== 2'b00 || HREADY !== 1)
                $fatal(1, "L1_ERR_TERMINATE_FAIL: %s — ERROR response did not terminate cleanly", check_id);
            check_step(check_id);
        end
    endtask

    initial begin
        repeat (2) @(posedge HCLK); #1;
        HRESETn = 1;
        repeat (2) @(posedge HCLK); #1;

        // --- V01: Slot 7 Canonical 4 Offsets Word Read & Write (Bridge Address Decode & Protocol) ---
        // Offset 0x00: HEX_VALUE
        issue(32'h40070000, 1, 3'b010, 32'h00123456); expect_ok(16'h0080, 32'h00000000);
        issue(32'h40070000, 0, 3'b010, 32'h0);        expect_ok(16'h0080, 32'h00123456);

        // Offset 0x04: HEX_CTRL
        issue(32'h40070004, 1, 3'b010, 32'h00000003); expect_ok(16'h0080, 32'h00000000);
        issue(32'h40070004, 0, 3'b010, 32'h0);        expect_ok(16'h0080, 32'h00000003);

        // Offset 0x08: HEX_RAW_LOW
        issue(32'h40070008, 1, 3'b010, 32'h00130c12); expect_ok(16'h0080, 32'h00000000);
        issue(32'h40070008, 0, 3'b010, 32'h0);        expect_ok(16'h0080, 32'h00130c12);

        // Offset 0x0C: HEX_RAW_HIGH
        issue(32'h4007000c, 1, 3'b010, 32'h000ce00f); expect_ok(16'h0080, 32'h00000000);
        issue(32'h4007000c, 0, 3'b010, 32'h0);        expect_ok(16'h0080, 32'h000ce00f);

        // --- Fault Injection Check for L1 (Mutation Mode) ---
        if ($test$plusargs("INJECT_L1_SUPPRESSION_FAULT")) begin
            $display("[MUTATION] INJECT_L1_SUPPRESSION_FAULT enabled: injecting PSEL leak on unmapped offset");
            force dut.PSEL = 16'h0080;
        end

        // --- V02 & V03: Non-canonical Offsets within Slot 7 ---
        issue(32'h40070010, 1, 3'b010, 32'hdeadbeef); expect_error("V02_OFFSET_10_WR");
        issue(32'h40070010, 0, 3'b010, 32'h0);        expect_error("V02_OFFSET_10_RD");
        issue(32'h40070014, 1, 3'b010, 32'hdeadbeef); expect_error("V02_OFFSET_14_WR");
        issue(32'h40070014, 0, 3'b010, 32'h0);        expect_error("V02_OFFSET_14_RD");
        issue(32'h40070100, 1, 3'b010, 32'hdeadbeef); expect_error("V02_OFFSET_100_WR");
        issue(32'h40070100, 0, 3'b010, 32'h0);        expect_error("V02_OFFSET_100_RD");
        issue(32'h4007fffc, 1, 3'b010, 32'hdeadbeef); expect_error("V02_OFFSET_FFFC_WR");
        issue(32'h4007fffc, 0, 3'b010, 32'h0);        expect_error("V02_OFFSET_FFFC_RD");

        // --- V02 & V03: Sub-word Accesses on Slot 7 Canonical Base ---
        // Byte accesses (HSIZE = 3'b000)
        issue(32'h40070000, 1, 3'b000, 32'h00000012); expect_error("V02_BYTE_WR_VAL");
        issue(32'h40070000, 0, 3'b000, 32'h0);        expect_error("V02_BYTE_RD_VAL");
        issue(32'h40070004, 1, 3'b000, 32'h00000001); expect_error("V02_BYTE_WR_CTRL");
        issue(32'h40070008, 1, 3'b000, 32'h000000aa); expect_error("V02_BYTE_WR_RAWL");
        issue(32'h4007000c, 1, 3'b000, 32'h00000055); expect_error("V02_BYTE_WR_RAWH");

        // Halfword accesses (HSIZE = 3'b001)
        issue(32'h40070000, 1, 3'b001, 32'h00003456); expect_error("V02_HALF_WR_VAL");
        issue(32'h40070000, 0, 3'b001, 32'h0);        expect_error("V02_HALF_RD_VAL");
        issue(32'h40070004, 1, 3'b001, 32'h00000001); expect_error("V02_HALF_WR_CTRL");
        issue(32'h40070008, 1, 3'b001, 32'h0000aaaa); expect_error("V02_HALF_WR_RAWL");
        issue(32'h4007000c, 1, 3'b001, 32'h00005555); expect_error("V02_HALF_WR_RAWH");

        // --- V02 & V03: Misaligned Addresses on Slot 7 Base ---
        issue(32'h40070001, 1, 3'b010, 32'hdeadbeef); expect_error("V02_MISALIGN_01_WR");
        issue(32'h40070001, 0, 3'b010, 32'h0);        expect_error("V02_MISALIGN_01_RD");
        issue(32'h40070002, 1, 3'b010, 32'hdeadbeef); expect_error("V02_MISALIGN_02_WR");
        issue(32'h40070002, 0, 3'b010, 32'h0);        expect_error("V02_MISALIGN_02_RD");
        issue(32'h40070003, 1, 3'b010, 32'hdeadbeef); expect_error("V02_MISALIGN_03_WR");
        issue(32'h40070005, 1, 3'b010, 32'hdeadbeef); expect_error("V02_MISALIGN_05_WR");

        // --- V03: Error Recovery to OKAY ---
        issue(32'h40070000, 0, 3'b010, 32'h0);
        expect_ok(16'h0080, 32'h00123456);

        issue(32'h40070004, 1, 3'b010, 32'h00000001);
        expect_ok(16'h0080, 32'h00000000);

        $display("SUMMARY: PASS HEX S5 L1 bridge checks=%0d", checks);
        $finish;
    end
endmodule
