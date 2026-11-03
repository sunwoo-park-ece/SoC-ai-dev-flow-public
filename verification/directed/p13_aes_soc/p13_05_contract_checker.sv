`timescale 1ns/1ps
// Independent accepted-transfer ledger. Observations never drive production.
module p13_05_contract_checker(input clk,reset_n,input [31:0] status,input [31:0] haddr,hwdata,hrdata,paddr,pwdata,prdata,input [1:0] htrans,hresp,input [2:0] hsize,input hwrite,hready,input [15:0] psel,input penable,pwrite,pready);
 integer cyc=0,id=0,owner_id=0;
 reg active=0,wr=0,setup=0;
 reg [31:0] addr=0,pa=0,pd=0;
 reg pw=0;
 always @(posedge clk) begin
 cyc=cyc+1;
 if (!reset_n) begin active=0;setup=0;end
 else begin
  if (active && hready) begin
   $display("EVENT AHB_DONE cycle=%0d id=%0d addr=%h wr=%0d resp=%h data=%h",cyc,owner_id,addr,wr,hresp,wr?hwdata:hrdata);
   if (hresp!==0) $fatal(1,"UNEXPECTED_AHB_ERROR");
   active=0;
  end
  if (psel[4] && !penable) begin
   if (!active || addr!==paddr || wr!==pwrite) $fatal(1,"BUS_PHASE_PAIR_SETUP");
   setup=1;pa=paddr;pw=pwrite;pd=pwdata;
  end
  if (psel[4] && penable) begin
   if (!setup || paddr!==pa || pwrite!==pw || (pw && pwdata!==pd)) $fatal(1,"APB_CONTROLS_STABLE");
   if (pready) begin
    if ((^prdata)===1'bx || (^pwdata)===1'bx) $fatal(1,"POST_RESET_APB_X");
    if (hready!==1 || hresp!==0 || (!pwrite && hrdata!==prdata)) $fatal(1,"BUS_RESPONSE_PAIR");
    $display("EVENT APB time=%0t cycle=%0d addr=%h wr=%0d data=%h before=%h",$time,cyc,paddr,pwrite,pwrite?pwdata:prdata,status);
    setup=0;
   end
  end
  // New address ownership applies after checking the old data phase.
  if (hready && htrans[1]) begin
   if (active) $fatal(1,"AHB_ORPHAN_OWNER");
   id=id+1;owner_id=id;active=1;addr=haddr;wr=hwrite;
   $display("EVENT AHB_ACCEPT cycle=%0d id=%0d addr=%h wr=%0d size=%h",cyc,id,haddr,hwrite,hsize);
  end
 end
 end
endmodule

// Isolated checker-input fixture: this top contains NO production DUT instance.
module tb_p13_05_checker_fixture;
 reg clk=0,rst=0,wr=0,ready=1,enable=0,pwr=0,prdy=1;
 reg [31:0] addr=0,wd=0,rd=0,pa=0,pd=0,pr=0;
 reg [1:0] trans=0,resp=0;
 reg [2:0] size=2;
 reg [15:0] sel=0;
 reg completed=0;
 integer fault=0;
 always #10 clk=~clk;
 p13_05_contract_checker u_check(.clk(clk),.reset_n(rst),.status(32'b0),.haddr(addr),.htrans(trans),.hsize(size),.hwrite(wr),.hwdata(wd),.hrdata(rd),.hready(ready),.hresp(resp),.psel(sel),.penable(enable),.paddr(pa),.pwrite(pwr),.pwdata(pd),.prdata(pr),.pready(prdy));
 initial begin
 if(!$value$plusargs("FAULT=%d",fault))fault=0;
 repeat(2)@(negedge clk);rst=1;
 @(negedge clk);addr=32'h40040008;trans=2;
 @(negedge clk);trans=0;ready=0;sel=16'h10;pa=32'h40040008;
 $display("FIXTURE_ACTIVATION fault=%0d layer=CHECKER_INPUT_ONLY",fault);
 if(fault==1)pa=32'h4004000c;
 @(negedge clk);ready=1;enable=1;pr=32'h322e3030;rd=32'h322e3030;
 if(fault==2)pa=32'h4004000c;
 if(fault==3)rd=0;
 if(fault==4)pr=32'hxxxxxxxx;
 if(fault==5)resp=1;
 @(negedge clk);sel=0;enable=0;
 completed=1;$display("FIXTURE_CONTROL_PASS");$finish;
 end
endmodule
