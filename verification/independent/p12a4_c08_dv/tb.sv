`timescale 1ns/1ps
module tb;
 reg hclk=0, hrun=1, pixel_clock=0, prun=1, lock=0, resetn=0;
 always #5 if(hrun) hclk=~hclk;
 always #7 if(prun) pixel_clock=~pixel_clock;
 reg [31:0] addr=0, wd=0; reg wr=0, sel=0, gin=1;
 reg [1:0] trans=0; reg [2:0] size=2;
 wire [31:0] rd; wire ready; wire [1:0] resp;
 AHB_VRAM_DUAL_BUFFER dut(.CLOCK_50(pixel_clock),.HCLK(hclk),.HRESETn(resetn),
 .HADDR(addr),.HWRITE(wr),.HTRANS(trans),.HSIZE(size),.HWDATA(wd),.HSEL(sel),
 .HREADY_IN(gin),.HRDATA(rd),.HREADY(ready),.HRESP(resp),.VGA_R(),.VGA_G(),.VGA_B(),.VGA_HS(),.VGA_VS());
 integer checks=0, transfers=0, id=0, commands=0, error_waits=0, cycles=0;
 integer expected_count=0, injection=0, lane=0, bad_port=0, wrong_read=0, monitor=0;
 reg active=0, fb=0, supported=0, rejected=0, refbusy=0, refready=0;
 reg [31:0] a, d, sample; reg direction; reg [2:0] sz;
 reg assoc=0; integer ncmd=0, twaits=0; reg [31:0] obsdata;
 task check(input bit ok,input string tag);
 begin checks=checks+1; if(!ok)begin $display("FAIL_%s t=%0t",tag,$time);$fatal(1);end end endtask
 task ticks(input integer n); repeat(n)begin @(posedge hclk);#1;end endtask
 // Address/control ownership comes only from accepted bus phases. Internal
 // wires below are actual RAM command observations, never expected values.
 always @(posedge hclk) if(resetn) begin
  cycles=cycles+1;
  if(active) begin
   assoc=assoc || !lock;
   if((fb || a==32'h20010004) && !lock)rejected=1;
   if(dut.u_VRAM0.wren || dut.u_VRAM1.wren)begin
    if(fb)begin
     ncmd=ncmd+1;commands=commands+1;
     $display("PORT id=%0d bank0=%0d bank1=%0d address=%0d data=%08h expected_word=%0d expected_data=%08h",id,dut.u_VRAM0.wren,dut.u_VRAM1.wren,dut.u_VRAM1.wraddress,dut.u_VRAM1.data,a[15:2],wd);
     check(!dut.u_VRAM0.wren && dut.u_VRAM1.wren,"PORT_BANK");
     check(dut.u_VRAM1.wraddress === a[15:2],"PORT_ADDRESS");
     obsdata=dut.u_VRAM1.data;
     if(bad_port)begin obsdata=obsdata^1; $display("ACTIVATE_PORT_DATA");end
     check(obsdata === wd,"PORT_DATA");
     check(ready && gin,"PORT_EARLY");
    end else check(refbusy,"ORPHAN_PORT");
   end
   if(resp==1 && !ready)begin check(rejected,"ERROR_UNEXPECTED");twaits=twaits+1;error_waits=error_waits+1;end
   if(ready && gin)begin
    check(resp === (rejected?2'b01:2'b00),"RESPONSE");
    check(twaits==(rejected?1:0),"ERROR_SEQUENCE");
    if(fb)check(ncmd==(rejected?0:1),"COMMAND_COUNT");
    if(a==32'h20010004 && direction && !rejected && wd[1:0]!=0) refbusy=1;
    transfers=transfers+1;
    $display("TX id=%0d addr=%08h wr=%0d size=%0d response=%0d commands=%0d loss=%0d data=%08h expected_response=%0d expected_commands=%0d expected_bank=1 expected_word=%0d terminal_ready=%0d terminal_global=%0d",id,a,direction,sz,resp,ncmd,assoc,wd,rejected?1:0,(fb && !rejected)?1:0,a[15:2],ready,gin);
    active=0;
   end
  end else if(dut.u_VRAM0.wren || dut.u_VRAM1.wren) check(refbusy,"ORPHAN_PORT");
  if(gin && ready && sel && trans[1])begin
   check(!active,"PHASE_OVERLAP"); active=1;id=id+1;a=addr;direction=wr;sz=size;
   fb=addr>=32'h20000000 && addr<=32'h200095ff && wr && size==2 && addr[1:0]==0;
   supported=size==2 && addr[1:0]==0 && (fb || addr==32'h20010000 || (addr==32'h20010004 && wr));
   rejected=!supported || ((fb || addr==32'h20010004) && (!refready || refbusy));
   ncmd=0;assoc=0;twaits=0;
  end
 end else begin active=0;refbusy=0;refready=0;end
 task launch(input [31:0] x,input bit w,input [2:0] s);
 begin @(negedge hclk);addr=x;wr=w;size=s;sel=1;trans=2;gin=1;@(posedge hclk);#1;end endtask
 task finish(input [31:0] data,input integer stall);
 integer k;
 begin @(negedge hclk);sel=0;trans=0;wd=data;gin=0;
 for(k=0;k<stall;k=k+1)begin @(posedge hclk);#1;@(negedge hclk);end
 gin=1;
 begin: wait_done
 for(k=0;k<8;k=k+1)begin @(posedge hclk);sample=rd;#1;if(!active)disable wait_done;end
 check(0,"BUS_TIMEOUT");end
 end endtask
 task bus(input [31:0] x,input bit w,input [31:0] data,input integer stall,input [2:0] s);
 begin launch(x,w,s);finish(data,stall);end endtask
 task status(input integer count,input integer fault);
 begin bus(32'h20010000,0,0,0,2);
 if(wrong_read)begin count=count+1;$display("ACTIVATE_READ_COUNT");end
 $display("READ expected_count=%0d expected_fault=%0d actual=%08h",count,fault,sample);
 check(sample[31:16]==count,"READ_COUNT");check(sample[5]==fault,"FAULT");check(sample[15:6]==0,"RESERVED");
 $display("STATUS expected_count=%0d expected_fault=%0d actual=%08h",count,fault,sample);end endtask
 task recover;begin lock=1;ticks(40);refready=1;refbusy=0;end endtask
 task loss(input integer lowcycles);begin @(negedge hclk);lock=0;refready=0;ticks(lowcycles);end endtask
 initial begin
  if($value$plusargs("LANE=%d",lane))begin end
  if($value$plusargs("MONITOR=%d",monitor))begin end
  if($value$plusargs("BAD_PORT=%d",bad_port))begin end
  if($value$plusargs("WRONG_READ=%d",wrong_read))begin end
  ticks(4);resetn=1;ticks(10);status(0,0);
  lock=1;ticks(1);@(negedge hclk);lock=0;ticks(1);lock=1;
  ticks(40);refready=1;status(0,0);$display("BIN UNARMED_QUALIFICATION");
  if(lane==2)begin
   // Reach saturation through 65536 real externally driven episodes; no seed.
   prun=0;pixel_clock=0;
   repeat(65534)begin loss(6);lock=1;ticks(16);end
   status(65534,0);loss(6);lock=1;ticks(16);status(65535,0);
   loss(6);lock=1;ticks(16);status(65535,0);$display("BIN SATURATION_REACHABLE episodes=65536");
  end else begin
   if(lane==1)begin injection=1;$display("ACTIVATE_UNASSOCIATED_INPUT");end
   bus(32'h20000000,1,32'ha1234567,0,2);
   injection=0;status(0,0);
   bus(32'h200095fc,1,32'hfefefefe,4,2);
   // Back-to-back data completion and next address acceptance.
   launch(32'h20000004,1,2);
   @(negedge hclk);addr=32'h20000008;wd=32'h11223344;
   @(posedge hclk);#1;
   finish(32'h55667788,0);
   bus(32'h20009600,1,1,2,2);bus(32'h20000000,0,0,0,2);
   bus(32'h20000001,1,0,0,2);bus(32'h20000000,1,0,0,1);
   bus(32'h20010004,0,0,0,2);bus(32'h20010004,1,0,0,2);
   status(0,0);
   // Lose lock in outstanding held FB phase; natural ERROR/zero port commands.
   launch(32'h20000010,1,2);
   @(negedge hclk);lock=0;refready=0;injection=lane==1?1:0;
   if(injection)$display("ACTIVATE_MONITOR_INPUT mode=%0d discriminator=%0d",injection,monitor);
   finish(32'h99887766,3);injection=0;ticks(8);status(1,lane==1 && monitor!=1);
   ticks(20);status(1,lane==1 && monitor!=1); // sustained low once
   if(lane==1)begin recover();status(1,monitor!=1);end
   // Retain fault/count through routine/zero/RO writes, then selective clear.
   bus(32'h20010000,1,0,0,2);status(1,lane==1 && monitor!=1);
   bus(32'h20010000,1,1,0,2);status(1,lane==1 && monitor!=1);
   bus(32'h20010000,1,3,0,2);status(1,lane==1 && monitor!=1);
   bus(32'h20010000,1,32'hffff0014,0,2);status(1,lane==1 && monitor!=1);
   bus(32'h20010000,1,32'h20,0,2);status(1,0);
   recover();status(1,0);
   // Untagged loss retirement cannot qualify a later unrelated matching write.
   bus(32'h20000024,1,32'h99999999,0,2);status(1,0);
   // A short external pulse with HCLK halted; held pending survives relock.
   @(negedge hclk);hrun=0;hclk=0;lock=0;refready=0;#3;lock=1;#60;
   hrun=1;ticks(1);
   // Raw lock has returned, but an untagged notice retires during this new
   // rejected FB phase. Even a bad isolated command observation cannot attach
   // the old loss to it; sampled raw lock stays high for this transaction.
   injection=lane==1?1:0;if(injection)$display("ACTIVATE_DELAYED_UNTAGGED");
   bus(32'h20000028,1,32'h12345678,0,2);injection=0;
   status(2,0);ticks(40);refready=1;status(2,0);
   // PCLK halt alone is no loss; real loss transfer does not require PCLK.
   prun=0;pixel_clock=0;ticks(10);status(2,0);loss(7);status(3,0);
   lock=1;ticks(40);status(3,0);prun=1;ticks(40);refready=1;
   // Quick pulses inside the disarmed interval coalesce, then rearm.
   loss(1);lock=1;#2;lock=0;#2;lock=1;ticks(40);refready=1;status(4,0);
   // Cleaner traffic excluded and abort history retained across epoch loss.
   bus(32'h20010004,1,2,0,2);ticks(12);
   bus(32'h20000020,1,0,0,2);status(4,0);
   loss(10);status(5,0);recover();status(5,0);
   // Recreate nonzero sticky history and prove HRESET clears it too.
   if(lane==1)begin
    launch(32'h20000030,1,2);
    @(negedge hclk);lock=0;refready=0;injection=1;
    finish(32'h12340020,2);injection=0;ticks(8);status(6,monitor!=1);
    recover();status(6,monitor!=1);
   end
   // Reset discards a pending captured event before retirement.
   @(negedge hclk);lock=0;resetn=0;refready=0;ticks(4);lock=1;resetn=1;ticks(40);refready=1;status(0,0);
   // Read completion at the retirement edge must return the pre-update image.
   launch(32'h20010000,0,2);
   @(negedge hclk);lock=0;refready=0;gin=0;sel=0;trans=0;
   ticks(2);@(negedge hclk);gin=1;
   @(posedge hclk);sample=rd;#1;
   check(sample[31:16]==0,"READ_PREUPDATE");check(!active,"READ_COMPLETION");
   $display("BIN READ_PREUPDATE actual=%08h",sample);
   status(1,0);
   $display("BIN MAIN initial acquisition loss sustained rearm hstop pstop reset cleaner held pipeline exclusions w1c");
  end
  check(!active,"OUTSTANDING");check(error_waits>0 || lane==2,"ERROR_NONVACUOUS");
  $display("SUMMARY C08 checks=%0d transfers=%0d commands=%0d error_waits=%0d lane=%0d",checks,transfers,commands,error_waits,lane);
  $finish;
 end
 initial begin #100000000; $fatal(1,"FAIL_WATCHDOG");end
endmodule
