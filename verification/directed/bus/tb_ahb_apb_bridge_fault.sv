`timescale 1ns/1ps
module tb_ahb_apb_bridge_fault;
    reg HCLK = 0, HRESETn = 0;
    reg [31:0] HADDR = 0, HWDATA = 0, PRDATA = 32'h12345678;
    reg HWRITE = 0, HSEL = 0, PREADY = 1, PSLVERR = 0;
    reg [1:0] HTRANS = 0;
    reg [2:0] HSIZE = 3'b010;
    wire [31:0] HRDATA, PADDR, PWDATA;
    wire HREADY, PCLK, PRESETn, PWRITE, PENABLE;
    wire [1:0] HRESP;
    wire [15:0] PSEL;
    wire HREADY_IN = HREADY;
    integer writes = 0, slot;
    always #5 HCLK = ~HCLK;
    always @(posedge HCLK)
        if (PSEL[1] && PENABLE && PWRITE && PREADY) writes <= writes + 1;

    AHB_APB_bridge dut (.*);

    task issue(input [31:0] addr, input wr, input [2:0] size, input [31:0] data);
        begin
            @(negedge HCLK);
            HADDR = addr; HWRITE = wr; HSIZE = size; HWDATA = data;
            HSEL = 1; HTRANS = 2'b10;
            @(posedge HCLK); #1;
            if (PADDR !== addr || HREADY !== 0 || PENABLE !== 0)
                $fatal(1, "SETUP address/control mismatch %h", addr);
            @(negedge HCLK);
            HSEL = 0; HTRANS = 0;
        end
    endtask

    task expect_ok(input [15:0] select);
        begin
            if (PSEL !== select || PWDATA !== HWDATA)
                $fatal(1, "SETUP PSEL/PWDATA got=%h/%h expected=%h/%h", PSEL, PWDATA, select, HWDATA);
            @(posedge HCLK); #1;
            if (PSEL !== select || PENABLE !== 1 || PADDR !== HADDR ||
                PWDATA !== HWDATA || HRESP !== 0 || HREADY !== PREADY)
                $fatal(1, "ACCESS mismatch select=%h", select);
            @(posedge HCLK); #1;
            if (PSEL !== 0 || HRESP !== 0 || HREADY !== 1)
                $fatal(1, "valid transfer did not retire");
        end
    endtask

    task expect_error;
        begin
            if (PSEL !== 0) $fatal(1, "invalid request selected real peripheral");
            @(posedge HCLK); #1;
            if (PSEL !== 0 || PENABLE !== 1 || HRESP !== 2'b01 || HREADY !== 0)
                $fatal(1, "first ERROR cycle missing");
            @(posedge HCLK); #1;
            if (PSEL !== 0 || HRESP !== 2'b01 || HREADY !== 1)
                $fatal(1, "final ERROR cycle missing");
            @(posedge HCLK); #1;
            if (HRESP !== 0 || HREADY !== 1)
                $fatal(1, "ERROR response did not terminate");
        end
    endtask

    initial begin
        repeat (2) @(posedge HCLK); #1; HRESETn = 1;
        for (slot = 0; slot < 16; slot = slot + 1) begin
            if (dut.decode_psel(32'h40000000 + (slot << 16)) !== (16'h0001 << slot))
                $fatal(1,"raw 16-slot one-hot decode failed slot=%0d",slot);
            issue(32'h40000000 + (slot << 16), 0, 3'b010, 0);
            if (slot < 10) expect_ok(16'h0001 << slot);
            else expect_error();
        end
        issue(32'h4001001c, 0, 3'b010, 0); expect_ok(16'h0002);
        issue(32'h40080004, 0, 3'b010, 0); expect_ok(16'h0100);
        issue(32'h40080008, 0, 3'b010, 0); expect_ok(16'h0100);
        issue(32'h40090000, 0, 3'b010, 0); expect_ok(16'h0200);
        issue(32'h4008000c, 1, 3'b010, 0); expect_error();
        issue(32'h40090004, 1, 3'b010, 0); expect_error();
        issue(32'h400a0000, 1, 3'b010, 0); expect_error();
        issue(32'h40010020, 1, 3'b010, 32'hdeadbeef);
        expect_error();
        if (writes != 0) $fatal(1, "invalid offset side effect");
        issue(32'h40010000, 1, 3'b000, 32'hdeadbeef);
        expect_error();
        if (writes != 0) $fatal(1, "unsupported size side effect");

        PREADY = 0;
        issue(32'h40010000, 1, 3'b010, 32'hcafebabe);
        if (PWDATA !== 32'hcafebabe) $fatal(1, "write data late in SETUP");
        @(posedge HCLK); #1;
        repeat (3) begin
            if (PADDR !== 32'h40010000 || PWRITE !== 1 || PWDATA !== 32'hcafebabe ||
                PSEL !== 16'h0002 || PENABLE !== 1 || HREADY !== 0)
                $fatal(1, "APB wait control instability");
            @(posedge HCLK); #1;
        end
        if (writes != 0) $fatal(1, "write committed while PREADY=0");
        @(negedge HCLK); PREADY = 1;
        @(posedge HCLK); #1;
        if (writes != 1 || HREADY !== 1 || PSEL !== 0)
            $fatal(1, "write was not committed exactly once");

        PREADY = 0;
        issue(32'h40000004, 0, 3'b010, 0);
        @(posedge HCLK); #1;
        repeat (2) begin
            if (PADDR !== 32'h40000004 || PWRITE !== 0 || PSEL !== 16'h0001 ||
                PENABLE !== 1 || HREADY !== 0 || HRESP !== 0)
                $fatal(1,"APB read wait instability");
            @(posedge HCLK); #1;
        end
        @(negedge HCLK); PREADY = 1;
        #1;
        if (HREADY !== 1 || HRDATA !== PRDATA)
            $fatal(1,"APB read completion data");
        @(posedge HCLK); #1;

        // A completed ACCESS can capture a new address into the next SETUP.
        issue(32'h40000004, 0, 3'b010, 0);
        @(posedge HCLK); #1;
        @(negedge HCLK);
        HADDR=32'h40020008; HSEL=1; HTRANS=2'b10;
        @(posedge HCLK); #1;
        if (PSEL !== 16'h0004 || PENABLE !== 0 || PADDR !== 32'h40020008 || HREADY !== 0)
            $fatal(1,"back-to-back APB SETUP");
        @(negedge HCLK); HSEL=0; HTRANS=0;
        @(posedge HCLK); #1;
        if (PSEL !== 16'h0004 || PENABLE !== 1 || HREADY !== 1)
            $fatal(1,"back-to-back APB ACCESS");
        @(posedge HCLK); #1;

        issue(32'h40010000, 0, 3'b010, 0);
        @(posedge HCLK); #1;
        PSLVERR = 1;
        #1;
        if (HRESP !== 2'b01 || HREADY !== 0 || HRDATA !== 0)
            $fatal(1, "PSLVERR first ERROR conversion");
        @(posedge HCLK); #1;
        if (HRESP !== 2'b01 || HREADY !== 1)
            $fatal(1, "PSLVERR final ERROR conversion");
        PSLVERR = 0;
        $display("SUMMARY: PASS AHB/APB slot, offset, wait, and ERROR checks");
        $finish;
    end
endmodule
