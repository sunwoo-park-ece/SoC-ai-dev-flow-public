`timescale 1ns/1ps
// Passive actual observations. Fault adapters never drive the DUT or oracle.
module p12a3_soc_vga_observer #(
 parameter integer FAULT_CASE=0,
 parameter [31:0] FAULT_PC=0,YOUNGER_PC=0,TERMINAL_PC=0,TRAP_PC=0,START_INSTRUCTION=0
);
 `define D tb_p12a3_soc_vga.dut
 `define R tb_p12a3_soc_vga.ref_model
 reg pending=0, pw=0; reg [31:0] pa=0; reg [2:0] ps=0;
 integer id=0, finals=0, writes=0, status_reads=0, noop=0, gap_wait=0,gap_final=0;
 integer boot=0,terminal=0,done=0,cause_diag=0,pc_diag=0,releases=0;
 integer dmem_physical=0,dmem_post=0,error_step=0,wait_edge=0;
 integer commit_id=0,noop_id=0,dmem_id=0; integer observed_edge; string phase_name;
 bit dmem_pending=0,want_dmem=0,gap_wait_post=0,gap_final_post=0;
 reg observed_dwe,observed_ready,observed_stall,observed_hold,observed_ex_hold;
 reg [1:0] observed_response; reg [3:0] observed_mask;
 reg [12:0] observed_daddr,dmem_word;
 reg [31:0] observed_ddata,dmem_expected,observed_dpost,observed_mem_pc,observed_wb_pc;
 integer ticks=0; string fault="NONE"; bit injected=0;
 reg ow0,ow1,req,reset_sample; bit commit_pending=0; reg [31:0] commit_data; reg [13:0] commit_address; reg [31:0] observed_instruction, observed_memory; bit noop_accepted=0; reg [31:0] wd,rd,csr_cause,csr_pc,ret_pc;
 integer actual_route; bit retired; reg [13:0] wa;
 initial begin void_dummy(); end
 task void_dummy; begin if (!$value$plusargs("OBS_FAULT=%s",fault)) fault="NONE"; end endtask
 task fail(input string pid); begin $display("G1_FAILURE %s id=%0d addr=%08x time=%0t",pid,id,pa,$time); $fatal(1,"%s",pid); end endtask
 task activation_for(input string tag,input [31:0] before_value,input [31:0] after_value,input integer origin_id);
 begin injected=1; $display("G1_ADAPTER %s before=%08x after=%08x id=%0d time=%0t",tag,before_value,after_value,origin_id,$realtime); end endtask
 task activation(input string tag,input [31:0] before_value,input [31:0] after_value);
 begin injected=1; $display("G1_ADAPTER %s before=%08x after=%08x id=%0d time=%0t",tag,before_value,after_value,id,$time); end endtask
 function automatic [31:0] expected_dmem(input [31:0] a);
  case(a)
   32'h10000000: expected_dmem=FAULT_CASE?32'h47314641:32'h47314f4b;
   32'h10000004: expected_dmem=32'd7;
   32'h10000008: expected_dmem=FAULT_PC;
   default: expected_dmem=32'hxxxxxxxx;
  endcase
 endfunction
 always @(posedge `D.HCLK) begin
  ticks=ticks+1; commit_pending=0; noop_accepted=0; dmem_pending=0; gap_wait_post=0; gap_final_post=0;
  if (`D.HRESETn) begin
   // Word stores: expected port values come from accepted address + firmware/ISA.
   want_dmem=pending && pw && `R.route(pa)==1 && `D.HREADY && `D.HRESP==0;
   observed_dwe=`D.u_memory.u_bram.wren;
   observed_daddr=`D.u_memory.u_bram.wraddress;
   observed_mask=`D.u_memory.u_bram.byteena_a;
   observed_ddata=`D.u_memory.u_bram.data;
   if (want_dmem) begin
    dmem_expected=expected_dmem(pa); dmem_word=(pa-32'h10000000)>>2; dmem_id=id;
    $display("G1_DMEM_PRE id=%0d edge=%0d time=%0t addr=%08x we=%0d wa=%0d mask=%0d data=%08x ready=%0d resp=%0d",id,ticks,$realtime,pa,observed_dwe,observed_daddr,observed_mask,observed_ddata,`D.HREADY,`D.HRESP);
    if (fault=="DMEM_WE" && !injected) begin activation("DMEM_WE",observed_dwe,0); observed_dwe=0; end
    if (fault=="DMEM_ADDR" && !injected) begin activation("DMEM_ADDR",observed_daddr,observed_daddr+1); observed_daddr=observed_daddr+1; end
    if (fault=="DMEM_MASK" && !injected) begin activation("DMEM_MASK",observed_mask,7); observed_mask=7; end
    if (fault=="DMEM_DATA" && !injected) begin activation("DMEM_DATA",observed_ddata,observed_ddata^1); observed_ddata=observed_ddata^1; end
    if (dmem_expected===32'hxxxxxxxx || observed_dwe!==1 || observed_daddr!==dmem_word || observed_mask!==4'hf || observed_ddata!==dmem_expected || `D.HWDATA!==dmem_expected) fail("FAIL_G1C_DMEM_PHYSICAL");
    dmem_pending=1; dmem_physical=dmem_physical+1;
   end else if (observed_dwe!==0) fail("FAIL_G1C_DMEM_PHYSICAL");
   if (pending && pa==32'h20009600) begin
    observed_ready=`D.HREADY; observed_response=`D.HRESP; observed_edge=ticks;
    observed_stall=`D.u_CPU.bus_stall_req; observed_hold=`D.u_CPU.bus_wait_hold; observed_ex_hold=`D.u_CPU.EX_MEM_stall;
    if (`D.HREADY) phase_name="FINAL"; else phase_name="WAIT";
    $display("G1_GAP_PHASE id=%0d edge=%0d time=%0t stage=%s ready=%0d resp=%0d bus_stall=%0d cpu_hold=%0d if_hold=%0d id_hold=%0d ex_hold=%0d wb_hold=%0d owner_pc=%08x owner_valid=%0d fault_final=%0d vwe=%0d%0d dwe=%0d",id,ticks,$realtime,phase_name,`D.HREADY,`D.HRESP,observed_stall,observed_hold,`D.u_CPU.IF_ID_stall,`D.u_CPU.ID_EX_stall,observed_ex_hold,`D.u_CPU.MEM_WB_stall,`D.u_CPU.MEM_pc,`D.u_CPU.MEM_valid,`D.u_CPU.bus_fault_final,`D.U_VRAM.vram1_we,`D.U_VRAM.vram0_we,`D.u_memory.u_bram.wren);
    if (error_step==0) begin
     if (fault=="ERR_WAIT_DROP" && !injected) begin activation("ERR_WAIT_DROP",observed_ready,1); observed_ready=1; end
     if (fault=="ERR_RESPONSE" && !injected) begin activation("ERR_RESPONSE",observed_response,0); observed_response=0; end
     if (fault=="ERR_HOLD" && !injected) begin activation("ERR_HOLD",observed_hold,0); observed_hold=0; end
     if (observed_response!==1) fail("FAIL_G1C_ERROR_RESPONSE");
     if (observed_ready!==0) fail("FAIL_G1C_ERROR_SEQUENCE");
     if (observed_stall!==1 || observed_hold!==1 || observed_ex_hold!==1 || `D.u_CPU.IF_ID_stall!==1 || `D.u_CPU.ID_EX_stall!==1 || `D.u_CPU.MEM_WB_stall!==1 || `D.u_CPU.MEM_pc!==FAULT_PC || `D.u_CPU.MEM_valid!==1 || `D.u_CPU.bus_fault_final!==0) fail("FAIL_G1C_CPU_HOLD");
     error_step=1; wait_edge=observed_edge; gap_wait_post=1;
    end else if (error_step==1) begin
     if (fault=="ERR_FINAL_DROP" && !injected) begin activation("ERR_FINAL_DROP",observed_ready,0); observed_ready=0; end
     if (fault=="ERR_ORDER" && !injected) begin activation("ERR_ORDER",observed_edge,observed_edge+1); observed_edge=observed_edge+1; end
     if (fault=="ERR_RELEASE" && !injected) begin activation("ERR_RELEASE",observed_hold,1); observed_hold=1; end
     if (observed_response!==1) fail("FAIL_G1C_ERROR_RESPONSE");
     if (observed_ready!==1 || observed_edge!=wait_edge+1) fail("FAIL_G1C_ERROR_SEQUENCE");
     if (observed_stall!==0 || observed_hold!==0 || observed_ex_hold!==0 || `D.u_CPU.MEM_WB_stall!==0 || `D.u_CPU.bus_fault_final!==1 || `D.u_CPU.MEM_pc!==FAULT_PC || `D.u_CPU.MEM_valid!==1) fail("FAIL_G1C_CPU_RELEASE");
     error_step=2; gap_final_post=1;
    end else fail("FAIL_G1C_ERROR_SEQUENCE");
   end
   ow0=`D.U_VRAM.vram0_we; ow1=`D.U_VRAM.vram1_we;
   wa=`D.U_VRAM.write_addr; wd=`D.U_VRAM.write_data; rd=`D.HRDATA;
   req=`D.U_VRAM.request_toggle_h;
   actual_route=`D.HSEL_VRAM_d?2:(`D.HSEL_MEM_d?1:0);
   retired=`D.u_CPU.commit_valid; ret_pc=`D.u_CPU.WB_pc;
   if (retired && ret_pc==0) begin
    observed_instruction=`D.u_CPU.WB_instruction;
    if (fault=="IMAGE" && !injected) begin activation("IMAGE",observed_instruction,observed_instruction^1); observed_instruction=observed_instruction^1; end
    if (observed_instruction!==START_INSTRUCTION) fail("FAIL_G1_IMAGE");
    if (fault=="BOOT" && !injected) activation("BOOT",1,0);
    else boot=boot+1;
   end
   if (retired && ret_pc==TERMINAL_PC) terminal=terminal+1;
   if (FAULT_CASE && retired && fault=="RETIRE" && gap_final>0 && !injected) begin
    activation("RETIRE",ret_pc,FAULT_PC); ret_pc=FAULT_PC;
   end
   if (FAULT_CASE && retired && fault=="YOUNGER" && gap_final>0 && !injected) begin activation("YOUNGER",ret_pc,YOUNGER_PC); ret_pc=YOUNGER_PC; end
   if (FAULT_CASE && retired && (ret_pc==FAULT_PC || (ret_pc>=YOUNGER_PC && ret_pc<TRAP_PC))) fail("FAIL_G1_RETIRE");
   if (retired) $display("G1_RETIRE pc=%08x edge=%0d time=%0t instruction=%08x",ret_pc,ticks,$realtime,`D.u_CPU.WB_instruction);
   if (pending && `D.HREADY) begin
    finals=finals+1;
    $display("G1_FINAL id=%0d addr=%08x write=%0d size=%0d data=%08x rdata=%08x resp=%0d route=%0d we=%0d%0d wa=%0d wd=%08x edge=%0d time=%0t ready=%0d",id,pa,pw,ps,`D.HWDATA,`D.HRDATA,`D.HRESP,actual_route,ow1,ow0,wa,wd,ticks,$realtime,`D.HREADY);
    if (fault=="ROUTE" && `R.route(pa)==2 && !injected) begin activation("ROUTE",actual_route,0); actual_route=0; end
    if (actual_route!=`R.route(pa)) fail("FAIL_G1_ROUTE");
    if (ps!=2) fail("FAIL_G1_PHASE");
    if (pa==32'h20009600) begin
     if (fault=="ERROR" && !injected) begin activation("ERROR",ow1,1); ow1=1; end
     if (`D.HRESP!==2'b01 || gap_wait!=1 || ow0 || ow1 || req || `D.U_VRAM.operation_busy || `D.U_VRAM.clear_we) fail("FAIL_G1_ERROR");
     gap_final=gap_final+1;
    end else begin
     if (`D.HRESP!==2'b00) fail("FAIL_G1_PHASE");
     if (pw && `R.framebuffer(pa)) begin
      if (fault=="PHASE" && !injected) begin activation("PHASE",wa,wa+1); wa=wa+1; end
      if (fault=="BANK" && !injected) begin activation("BANK",ow1,0); ow1=0; ow0=1; end
      if (fault=="DATA" && !injected) begin activation("DATA",wd,wd^1); wd=wd^1; end
      if (wa!==((pa-32'h20000000)>>2)) fail("FAIL_G1_PHASE");
      if (ow0!==0 || ow1!==1 || wd!==`D.HWDATA) fail("FAIL_G1_COMMIT");
      if (writes==0 && (pa!=32'h20000000 || `D.HWDATA!=32'h12345678)) fail("FAIL_G1_COMMIT");
      if (writes==1 && (pa!=32'h200095fc || `D.HWDATA!=32'h89abcdef)) fail("FAIL_G1_COMMIT");
      commit_pending=1; commit_id=id; commit_address=(pa-32'h20000000)>>2; commit_data=`D.HWDATA; writes=writes+1;
     end else if (ow0 || ow1) fail("FAIL_G1_COMMIT");
     if (!pw && pa==32'h20010000) begin
      if (fault=="STATUS" && !injected) begin activation("STATUS",rd,rd|32'h20); rd=rd|32'h20; end
      if ((rd & 32'hffffffee)!==0) fail("FAIL_G1_STATUS");
      if (rd[4]) status_reads=status_reads+1;
     end
     if (pw && pa==32'h20010004) begin
      if (`D.HWDATA!==0 || req || `D.U_VRAM.operation_busy || `D.U_VRAM.clear_we) fail("FAIL_G1_NOOP");
      noop_accepted=1; noop_id=id; noop=noop+1;
     end
     if (pw && pa==32'h10000004) begin if (`D.HWDATA!==7) fail("FAIL_G1_CPU_FAULT"); cause_diag=cause_diag+1; end
     if (pw && pa==32'h10000008) begin if (`D.HWDATA!==FAULT_PC) fail("FAIL_G1_CPU_FAULT"); pc_diag=pc_diag+1; end
     if (pw && pa==32'h10000000) begin
      if (`D.HWDATA!==(FAULT_CASE?32'h47314641:32'h47314f4b)) fail("FAIL_G1_BOOT"); done=done+1;
     end
     if (pw && pa==32'h1000000c) fail("FAIL_G1_RETIRE");
    end
   end else if (pending && pa==32'h20009600) begin
    if (`D.HRESP!==1 || `D.HREADY!==0 || ow0 || ow1) fail("FAIL_G1_ERROR");
    gap_wait=gap_wait+1; $display("G1_GAP_WAIT id=%0d edge=%0d time=%0t ready=%0d resp=%0d",id,ticks,$realtime,`D.HREADY,`D.HRESP);
   end else if (ow0 || ow1) fail("FAIL_G1_COMMIT");
   if (`D.HREADY) begin
    pending=(`D.HTRANS[1] && `D.HRESP!=1);
    if (pending) begin id=id+1;pa=`D.HADDR;pw=`D.HWRITE;ps=`D.HSIZE; $display("G1_ADDR id=%0d addr=%08x write=%0d size=%0d edge=%0d time=%0t ready=%0d resp=%0d",id,pa,pw,ps,ticks,$realtime,`D.HREADY,`D.HRESP); end
   end
  end
  #0.001;
  if (dmem_pending) begin
   observed_dpost=`D.u_memory.u_bram.words[dmem_word];
   $display("G1_DMEM_POST id=%0d edge=%0d time=%0t wa=%0d actual=%08x",dmem_id,ticks,$realtime,dmem_word,observed_dpost);
   if (fault=="DMEM_POST" && !injected) begin activation_for("DMEM_POST",observed_dpost,observed_dpost^1,dmem_id); observed_dpost=observed_dpost^1; end
   if (fault=="DMEM_FAULT_POST" && !injected) begin activation_for("DMEM_FAULT_POST",observed_dpost,observed_dpost^1,dmem_id); observed_dpost=observed_dpost^1; end
   if (observed_dpost!==dmem_expected) fail("FAIL_G1C_DMEM_POST");
   dmem_post=dmem_post+1;
  end
  if (gap_wait_post) begin
   observed_mem_pc=`D.u_CPU.MEM_pc;
   $display("G1_GAP_POST id=%0d edge=%0d time=%0t stage=WAIT owner_pc=%08x owner_valid=%0d",id,ticks,$realtime,observed_mem_pc,`D.u_CPU.MEM_valid);
   if (fault=="ERR_HOLD_PC" && !injected) begin activation("ERR_HOLD_PC",observed_mem_pc,observed_mem_pc+4); observed_mem_pc=observed_mem_pc+4; end
   if (observed_mem_pc!==FAULT_PC || `D.u_CPU.MEM_valid!==1) fail("FAIL_G1C_CPU_HOLD");
  end
  if (gap_final_post) begin
   observed_wb_pc=`D.u_CPU.WB_pc;
   $display("G1_GAP_POST id=%0d edge=%0d time=%0t stage=FINAL active=%0d wb_pc=%08x wb_valid=%0d wb_exc=%0d",id,ticks,$realtime,`D.u_CPU.access_fault_active,observed_wb_pc,`D.u_CPU.WB_valid,`D.u_CPU.WB_exc_valid);
   if (fault=="ERR_TOKEN" && !injected) begin activation("ERR_TOKEN",observed_wb_pc,observed_wb_pc+4); observed_wb_pc=observed_wb_pc+4; end
   if (`D.u_CPU.access_fault_active!==1 || observed_wb_pc!==FAULT_PC || `D.u_CPU.WB_valid!==1 || `D.u_CPU.WB_exc_valid!==1) fail("FAIL_G1C_CPU_RELEASE");
  end
  if (commit_pending) begin
   observed_memory=`D.U_VRAM.u_VRAM1.words[commit_address];
   $display("G1_COMMIT_POST bank=1 addr=%0d actual=%08x expected=%08x id=%0d edge=%0d time=%0t",commit_address,observed_memory,commit_data,commit_id,ticks,$realtime);
   if (fault=="MEMORY" && !injected) begin activation_for("MEMORY",observed_memory,observed_memory^1,commit_id); observed_memory=observed_memory^1; end
   if (observed_memory!==commit_data) fail("FAIL_G1_COMMIT");
  end
  if (`D.HRESETn) begin
   req=`D.U_VRAM.request_toggle_h;
   if (noop_accepted) $display("G1_NOOP_POST request=%0d busy=%0d clear=%0d front=%0d id=%0d edge=%0d time=%0t",req,`D.U_VRAM.operation_busy,`D.U_VRAM.clear_we,`D.U_VRAM.front_bank_h,noop_id,ticks,$realtime);
   if (noop_accepted && fault=="NOOP" && !injected) begin $display("G1_NOOP_ORIGIN id=%0d edge=%0d",noop_id,ticks); activation_for("NOOP",req,1,noop_id); req=1; end
   if (req!==0 || `D.U_VRAM.operation_busy!==0 || `D.U_VRAM.clear_we!==0 || `D.U_VRAM.front_bank_h!==0) begin
    if (FAULT_CASE) fail("FAIL_G1_ERROR"); else fail("FAIL_G1_NOOP");
   end
  end
  reset_sample=`D.HRESETn;
  if (fault=="RESET" && ticks==20 && !injected) begin activation("RESET",reset_sample,1); reset_sample=1; end
  if (reset_sample!==`R.released) fail("FAIL_G1_RESET");
  if (`R.released && releases==0) begin releases=1; $display("G1_RESET_RELEASE qualified=1000000 time=%0t",$time); end
  if (`D.HRESETn && gap_final>0 && done>0) begin
   csr_cause=`D.u_CPU.csr_file.mcause; csr_pc=`D.u_CPU.csr_file.mepc;
   $display("G1_CSR_POST cause=%08x mepc=%08x expected_pc=%08x",csr_cause,csr_pc,FAULT_PC);
   if (fault=="CAUSE" && !injected) begin activation("CAUSE",csr_cause,6);csr_cause=6;end
   if (fault=="MEPC" && !injected) begin activation("MEPC",csr_pc,csr_pc+4);csr_pc=csr_pc+4;end
   if (csr_cause!==7 || csr_pc!==FAULT_PC) fail("FAIL_G1_CPU_FAULT");
  end
  if (done>0 && terminal>=8) begin
   if (dmem_physical!=(FAULT_CASE?3:1) || dmem_post!=dmem_physical || (FAULT_CASE && error_step!=2)) fail("FAIL_G1C_REACH");
   if (boot==0) fail("FAIL_G1_BOOT");
   if (pending || releases!=1 || done!=1 || status_reads<1) fail("FAIL_G1_REACH");
   if (FAULT_CASE) begin if (gap_final!=1 || gap_wait!=1 || writes!=0 || cause_diag!=1 || pc_diag!=1) fail("FAIL_G1_REACH"); end
   else if (writes!=2 || noop!=1 || status_reads<2 || gap_final!=0) fail("FAIL_G1_REACH");
   if (fault!="NONE" && !injected) fail("FAIL_G1_ADAPTER_REACH");
   $display("G1_SUMMARY PASS boot=%0d release=%0d status=%0d writes=%0d noop=%0d gap_wait=%0d gap_final=%0d cause_diag=%0d pc_diag=%0d done=%0d terminal=%0d finals=%0d dmem_physical=%0d dmem_post=%0d",boot,releases,status_reads,writes,noop,gap_wait,gap_final,cause_diag,pc_diag,done,terminal,finals,dmem_physical,dmem_post);
   $finish;
  end
 end
 `undef D
 `undef R
endmodule
