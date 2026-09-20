`timescale 1ns/1ps
// P09B transport/reset check at the external pins. No local reset-delay or
// obsolete 11-command assumptions are used.
module tb_gsensor_single_pclk;
    reg clk = 0, rst_n = 0;
    reg [2:1] sensor_int = 0;
    reg sensor_sdo = 0;
    wire [31:0] prdata;
    wire pready, pslverr, cs_n, sclk, mosi;
    wire [15:0] debug_x, debug_y;
    integer edges = 0, frames = 0, falls = 0, rises = 0, checks = 0;
    time last_edge = 0, last_spi_edge = 0;
    reg [15:0] expected [0:11];
    reg [15:0] observed;
    integer bit_idx;
    always #10 clk = ~clk;
    always @(posedge clk) begin edges = edges + 1; last_edge = $time; end
    APB_GSENSOR_MB dut (
        .PCLK(clk), .PRESETn(rst_n), .PADDR(32'h0), .PWRITE(1'b0),
        .PSEL(1'b0), .PENABLE(1'b0), .PWDATA(32'h0), .PRDATA(prdata),
        .PREADY(pready), .PSLVERR(pslverr), .GSENSOR_CS_N(cs_n),
        .GSENSOR_INT(sensor_int), .GSENSOR_SCLK(sclk), .GSENSOR_SDI(mosi),
        .GSENSOR_SDO(sensor_sdo), .debug_acc_x(debug_x), .debug_acc_y(debug_y)
    );
    task automatic fail(input [255:0] why);
        begin $display("FAIL %0s edge=%0d frame=%0d", why, edges, frames); $fatal(1); end
    endtask
    always @(sclk) begin
        if (rst_n && $time > 0 && $time != last_edge)
            fail("SCLK changed outside PCLK edge");
    end
    always @(cs_n) begin
        if (rst_n && $time > 0 && $time != last_edge)
            fail("CS changed outside PCLK edge");
    end
    initial begin
        expected[0]=16'h2420; expected[1]=16'h2503;
        expected[2]=16'h2601; expected[3]=16'h277f;
        expected[4]=16'h2809; expected[5]=16'h2946;
        expected[6]=16'h2c09; expected[7]=16'h2f00;
        expected[8]=16'h2e80; expected[9]=16'h3100;
        expected[10]=16'h2007; expected[11]=16'h2d08;
        @(posedge clk); #1;
        if (cs_n !== 1 || sclk !== 1 || mosi !== 0) fail("reset idle pins");
        @(negedge clk); rst_n = 1;
        @(posedge clk); #1;
        if (cs_n !== 0) fail("unexpected local reset delay");
        repeat (3) @(posedge sclk);
        @(negedge clk); rst_n = 0;
        #1;
        if (cs_n !== 1 || sclk !== 1 || mosi !== 0 ||
            debug_x !== 0 || debug_y !== 0) fail("asynchronous abort");
        repeat (3) @(posedge clk);
        if (cs_n !== 1) fail("transfer continued in reset");
        @(negedge clk); rst_n = 1;
        for (frames=0; frames<12; frames=frames+1) begin
            @(negedge cs_n);
            if (sclk !== 1) fail("Mode-3 idle polarity");
            observed = 0; falls = 0; rises = 0; last_spi_edge = $time;
            for (bit_idx=0; bit_idx<16; bit_idx=bit_idx+1) begin
                @(negedge sclk);
                if ($time-last_spi_edge != 240) fail("SCLK high half period");
                last_spi_edge = $time; falls = falls+1;
                #1;
                if (cs_n !== 0 || mosi !== expected[frames][15-bit_idx])
                    fail("MOSI write bit");
                @(posedge sclk);
                if ($time-last_spi_edge != 260) fail("SCLK low half period");
                last_spi_edge = $time; rises = rises+1;
                #1;
                observed = {observed[14:0], mosi};
            end
            @(posedge cs_n);
            if ($time-last_spi_edge != 240 || sclk !== 1 ||
                falls != 16 || rises != 16 || observed !== expected[frames])
                fail("CS hold/frame completeness");
            checks = checks + 1;
        end
        repeat (3) @(posedge clk);
        #1;
        if (cs_n !== 1) fail("extra init/read without IRQ");
        @(negedge clk); sensor_int[1] = 1;
        @(negedge cs_n); // First 56-bit read after initial-high IRQ.
        repeat (3) @(posedge sclk);
        @(negedge clk); rst_n = 0;
        #1;
        if (cs_n !== 1 || sclk !== 1 || mosi !== 0 ||
            dut.gsensor_ready !== 0 || dut.live_valid !== 0 ||
            dut.hold_valid !== 0)
            fail("56-bit read abort leaked completion");
        repeat (3) @(posedge clk);
        @(negedge clk); sensor_int[1] = 0; rst_n = 1;
        @(negedge cs_n);
        if (mosi !== expected[0][15] || sclk !== 1)
            fail("read abort did not restart first init command");
        checks = checks + 1;
        $display("SUMMARY: PASS single-PCLK reset/Mode-3 checks=%0d", checks);
        $finish;
    end
    initial begin #200_000; fail("global timeout"); end
endmodule
