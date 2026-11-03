`timescale 1ns/1ps
// Expected programming history comes from accepted APB writes, never DUT state.
// Callers supply contract/oracle expectations; all comparisons reject X/Z.
module p13_04_contract_scoreboard(
  input wire PCLK, PRESETn, PSEL, PENABLE, PWRITE, locked,
  input wire [31:0] PADDR, PWDATA
);
  reg [31:0] programmed[0:15];
  integer j, checks=0;
  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) for (j=0;j<16;j=j+1) programmed[j]<=0;
    else if (PSEL && PENABLE && PWRITE && !locked) begin
      if (PADDR==32'h4004000c && PWDATA==8)
        for (j=0;j<16;j=j+1) programmed[j]<=0;
      else if (PADDR>=32'h40040020 && PADDR<=32'h4004005c && PADDR[1:0]==0)
        programmed[(PADDR-32'h40040020)>>2]<=PWDATA;
    end
  end
  task require_true(input string id, input reg ok);
    begin
      if (ok!==1'b1) begin $display("ASSERT_FAIL %s",id); $fatal(1,"CONTRACT_REJECTION %s",id); end
      checks=checks+1; $display("ASSERT_PASS %s",id);
    end
  endtask
  task check32(input string id,input reg [31:0] observed,expected);
    begin
      $display("CHECK32 %s expected=%08h observed=%08h",id,expected,observed);
      require_true(id,observed===expected);
    end
  endtask
  task check128(input string id,input reg [127:0] observed,expected,mask);
    begin
      $display("CHECK128 %s expected=%032h observed=%032h mask=%032h",id,expected,observed,mask);
      require_true(id,(observed & mask)===(expected & mask));
    end
  endtask
  task status_summary(input reg [31:0] s);
    begin
      require_true("STATUS_SUMMARIES",s[4]===(|s[8:6]) && s[5]===(|s[12:9]) &&
        s[3]===(s[4]|s[5]) && s[31:14]===0 && (!s[13] || (s[0] && !s[1])));
    end
  endtask
endmodule
