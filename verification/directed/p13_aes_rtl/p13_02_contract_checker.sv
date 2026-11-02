`timescale 1ns/1ps
// Expectations are frozen-contract constants, independent AESGCM vectors, or
// the history of accepted external APB writes. No DUT register is an oracle.
module p13_02_contract_checker(
  input wire clk, resetn, psel, penable, pwrite, lock_inputs,
  input wire [31:0] paddr, pwdata
);
  reg [31:0] programmed [0:15];
  integer i, checks=0;
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      for (i=0;i<16;i=i+1) programmed[i] <= 0;
    end else if (psel && penable && pwrite && !lock_inputs) begin
      if (paddr==32'h4004000c && pwdata==8)
        for (i=0;i<16;i=i+1) programmed[i] <= 0;
      else if (paddr>=32'h40040020 && paddr<=32'h4004005c && paddr[1:0]==0)
        programmed[(paddr-32'h40040020)/4] <= pwdata;
    end
  end
  task check32(input string id, input [31:0] observed, expected);
    begin
      checks=checks+1;
      if (observed !== expected) begin
        $display("ASSERT_FAIL %0s expected=%08x observed=%08x",id,expected,observed);
        $fatal(1,"contract rejection");
      end
      $display("ASSERT_PASS %0s expected=%08x observed=%08x",id,expected,observed);
    end
  endtask
  task check128(input string id, input [127:0] observed, expected, mask);
    begin
      checks=checks+1;
      if ((observed & mask) !== (expected & mask)) begin
        $display("ASSERT_FAIL %0s expected=%032x observed=%032x mask=%032x",id,expected,observed,mask);
        $fatal(1,"vector rejection");
      end
      $display("ASSERT_PASS %0s expected=%032x observed=%032x mask=%032x",id,expected,observed,mask);
    end
  endtask
  task require_true(input string id, input condition);
    begin check32(id,{31'b0,condition},32'd1); end
  endtask
  task check_programmed(input string id, input integer slot, input [31:0] observed);
    begin check32(id,observed,programmed[slot]); end
  endtask
endmodule
