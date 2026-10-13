`timescale 1ns/1ps
module tb_g2;
 parameter IMEM_FILE="";
 parameter integer LANE=0;
 parameter [31:0] FAULT_PC=0,YOUNGER_PC=0,TRAP_PC=0,START_WORD=0;
 reg clk=0; always #10 clk=~clk;
 reg [1:0] key=2'b10;
 AMBA_SoC_TOP dut(.clk(clk),.KEY(key),.SW(10'b0),.G_SENSOR_INT(2'b0),
 .G_SENSOR_SDO(1'b0),.lora_rx(1'b1),.lora_aux(1'b1),.uart_rx(1'b1));
 defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE=IMEM_FILE;
 // External-history oracle: qualified reset and modeled PLL environment.
 p12a3_soc_vga_ref reset_ref(clk,key[0],);
 reg env_lock=0,env_c0=0; integer env_count=0;
 reg pq1=0,pq2=0; integer x=0,y=0,frames=0;
 // Admission is sampled BEFORE the HCLK NBA that qualifies reset. At a
 // coincident generated pixel edge that newly released value has not yet
 // traversed the DUT's combinational reset-request path (diagnosed in raw).
 reg env_release_at_hclk=0;
 integer observed_x,observed_y;reg timing_fault=0,timing_injected=0;
 initial timing_fault=$test$plusargs("TIMING_FAULT");
 always @(posedge clk)env_release_at_hclk=reset_ref.released && env_lock;
 reg injected=0,key_injected=0;
 reg pending=0,pw=0; reg [31:0] pa=0; reg [2:0] ps=0;
 integer edge_no=0,id=0,epoch=0,commands=0,command=0;
 integer clear_count=0,front=0,hfront=0,target=1;
 integer commits=0,acks=0,owners=0,dones=0,canceled=0,boots=0;
 integer words_written=0,render_round=0,done_edge=0,commit_edge=0;
 integer errors=0,error_step=0,error_edge=0,apb_wait=0,dmem=0,pixels=0;
 reg [5:0] p4_recovery_pixels=0;
 integer p4_recovery_frame=-1;
 integer req_before=0,ack_before=0,bank_before=0,hbank_before=0;
 integer terminal=0,diag_cause=0,diag_pc=0,signature=0;
 integer last_status=-1,last_done=0,last_abort=0,aborts=0,ready_drop=0;
 integer last_command_id=0,request_events=0,ack_events=0;
 reg active=0,await_commit=0,armed=0,clearing=0,loss_pending=0;
 reg [31:0] memory0[0:9599],memory1[0:9599];
 reg [31:0] expected_word,post_word; integer bank,wa; reg [31:0] wd;
 integer pre_status,post_status,w1c_mask; reg w1c=0;
 reg was_reset=1,reset_now;
 // Passive first-release diagnostics: ACTIVE versus settled (+1ps/+2ps).
 task timing_diag(input string phase);
 begin
  $display("G2_TIMING_DIAG phase=%s time_ps=%0.0f edge=%0d clk=%0d pixel=%0d env_pixel=%0d raw_lock=%0d env_lock=%0d hreset=%0d ref_hreset=%0d request_reset=%0d stages=%02b pixel_reset=%0d ref_stages=%0d%0d ref_reset=%0d actual_x=%0d actual_y=%0d expected_x=%0d expected_y=%0d",phase,$realtime*1000,edge_no,clk,dut.U_VRAM.pclk_25,env_c0,dut.U_VRAM.vga_pll_locked,env_lock,dut.HRESETn,reset_ref.released,dut.U_VRAM.u_vga_reset_sync.async_reset_n,dut.U_VRAM.u_vga_reset_sync.sync_ff,dut.U_VRAM.vga_reset_n,pq2,pq1,pq2,dut.U_VRAM.h_cnt,dut.U_VRAM.v_cnt,x,y);
 end endtask
 always @(posedge clk)begin
  if(edge_no>=1000004 && edge_no<=1000020)begin timing_diag("HCLK_ACTIVE");#0.001;timing_diag("HCLK_SETTLED");end
 end
 always @(posedge env_c0)begin
  if(edge_no>=1000004 && edge_no<=1000020)begin timing_diag("PIXEL_ACTIVE");#0.001;timing_diag("PIXEL_SETTLED");end
 end
 task fail(input string pid); begin $display("G2_FAILURE %s edge=%0d id=%0d",pid,edge_no,id);$fatal(1,"%s",pid); end endtask
 function automatic integer route(input [31:0] a);
  if(a>=32'h20000000 && a<32'h20020000) route=2;
  else if(a>=32'h10000000 && a<32'h10008000) route=1;
  else if(a[31:20]==12'h400) route=3; else route=0;
 endfunction
 task reset_ledger;
 begin
  if(active)begin canceled=canceled+1;$display("G2_CANCEL epoch=%0d edge=%0d command=%0d clear=%0d committed=%0d",epoch,edge_no,command,clear_count,!await_commit && (command&1));end
  active=0;await_commit=0;clearing=0;armed=0;front=0;hfront=0;target=1;
  req_before=0;ack_before=0;bank_before=0;hbank_before=0;last_done=0;
 end endtask
 initial begin
  for(integer i=0;i<9600;i=i+1)begin memory0[i]=0;memory1[i]=0;end
  $display("G2_IMAGE lane=%0d path=%s start=%08x fault_pc=%08x",LANE,IMEM_FILE,START_WORD,FAULT_PC);
  repeat(5)@(negedge clk);#5 key[0]=1;
  #160000000;fail("G2_REACH");
 end
 // The independent model predicts only the existing environment hook, never
 // reads Production lock/reset/counter/bank to calculate expected timing.
 always @(posedge clk)begin
  env_c0<=~env_c0;
  if(!env_lock)begin if(env_count==3)env_lock<=1;else env_count<=env_count+1;end
 end
 always @(posedge env_c0 or negedge reset_ref.released or negedge env_lock)begin
  if(!env_release_at_hclk || !reset_ref.released || !env_lock)begin pq1<=0;pq2<=0;end
  else begin pq1<=1;pq2<=pq1;end
 end
 always @(posedge env_c0 or negedge pq2)begin
  if(!pq2)begin x=0;y=0;end
  else begin
   if(x==799 && y==524)begin
    frames=frames+1;
    $display("G2_WRAP epoch=%0d edge=%0d frame=%0d x=799 y=524",epoch,edge_no,frames);
    if(await_commit)begin front=1-front;await_commit=0;armed=1;commits=commits+1;commit_edge=edge_no;
     $display("G2_EXPECT_COMMIT epoch=%0d edge=%0d op=%0d front=%0d",epoch,edge_no,last_command_id,front);
    end
   end
   if(x==799)begin x=0;if(y==524)y=0;else y=y+1;end else x=x+1;
  end
  #0.002;
  observed_x=dut.U_VRAM.h_cnt;observed_y=dut.U_VRAM.v_cnt;
  if(timing_fault && !timing_injected && pq2 && x==32 && y==0)begin
   $display("G2_TIMING_ADAPTER edge=%0d before_x=%0d after_x=%0d expected_x=%0d expected_y=%0d",edge_no,observed_x,observed_x+1,x,y);
   observed_x=observed_x+1;timing_injected=1;
  end
  if(edge_no>=1000007 && (edge_no<=1000025 || x==0 || x==799 || (x==32 && y==0)))
   $display("G2_TIMING_SAMPLE phase=SETTLED_2PS time_ps=%0.0f edge=%0d actual_x=%0d actual_y=%0d expected_x=%0d expected_y=%0d",$realtime*1000,edge_no,observed_x,observed_y,x,y);
  if(observed_x!==x || observed_y!==y)begin timing_diag("COMPARATOR_MISMATCH");fail("G2_TIMING");end
  if(dut.U_VRAM.front_bank_p!==front)fail("G2_CAUSALITY");
  if(armed && x<640 && y<480 && ((y==0 && (x==0 || x==31 || x==32 || x==639)) || (y==479 && (x==0 || x==639))))begin
   expected_word=front?memory1[y*20+x/32]:memory0[y*20+x/32];
   $display("G2_PIXEL epoch=%0d edge=%0d frame=%0d x=%0d y=%0d front=%0d word=%08x rgb=%03x",epoch,edge_no,frames,x,y,front,expected_word,{dut.U_VRAM.VGA_R,dut.U_VRAM.VGA_G,dut.U_VRAM.VGA_B});
   if({dut.U_VRAM.VGA_R,dut.U_VRAM.VGA_G,dut.U_VRAM.VGA_B} !== (expected_word[x%32]?12'hfff:12'h000))fail("G2_PIXEL");pixels=pixels+1;
   // P4 completion requires distinct, checked coordinates in one fresh frame.
   if(LANE==4 && injected && epoch==1)begin
    if(p4_recovery_frame!=frames)begin p4_recovery_pixels=0;p4_recovery_frame=frames;end
    if(y==0)begin
     case(x)
      0:p4_recovery_pixels[0]=1;
      31:p4_recovery_pixels[1]=1;
      32:p4_recovery_pixels[2]=1;
      639:p4_recovery_pixels[3]=1;
     endcase
    end else if(y==479)begin
     if(x==0)p4_recovery_pixels[4]=1;
     if(x==639)p4_recovery_pixels[5]=1;
    end
   end
  end
 end
 // Race-safe modeled loss: negedge external HCLK +5ns, never a sample edge.
 initial begin
  if(LANE==4)begin
   wait(commits==1);repeat(20)@(negedge clk);#5;
   if(!reset_ref.released || !active || clear_count==9600)fail("G2_PLL_PHASE");
   $display("G2_PLL_INJECT epoch=%0d edge=%0d clear=%0d commit_edge=%0d hreset=%0d model_lock=%0d",epoch,edge_no,clear_count,commit_edge,dut.HRESETn,dut.U_VRAM.U_PLL.locked);
   dut.U_VRAM.U_PLL.inject_lock_loss();env_lock=0;env_count=0;injected=1;loss_pending=1;
   #0.002;
   $display("G2_PLL_BIND edge=%0d model_lock=%0d raw_lock=%0d preset=%0d hepoch=%0d hreset=%0d we=%0d%0d",edge_no,dut.U_VRAM.U_PLL.locked,dut.U_VRAM.vga_pll_locked,dut.U_VRAM.vga_reset_n,dut.U_VRAM.h_epoch_valid,dut.HRESETn,dut.U_VRAM.vram1_we,dut.U_VRAM.vram0_we);
   if(dut.U_VRAM.vga_pll_locked!==0 || dut.U_VRAM.vga_reset_n!==0 || dut.U_VRAM.h_epoch_valid!==0 || dut.HRESETn!==1 || dut.U_VRAM.vram0_we || dut.U_VRAM.vram1_we)fail("G2_PLL");
   reset_ledger();epoch=epoch+1;
  end
 end
 initial begin
  if(LANE==3)begin
   wait(commands==1);@(negedge clk);#5;
   if(commits!=0)fail("G2_RESET_PHASE");
   $display("G2_KEY_INJECT edge=%0d epoch=%0d commands=%0d commits=%0d",edge_no,epoch,commands,commits);
   key[0]=0;key_injected=1;
   repeat(5)@(negedge clk);#5 key[0]=1;
  end
 end
 always @(posedge clk)begin
  edge_no=edge_no+1;w1c=0;reset_now=!dut.HRESETn;
  if(reset_now)begin
   pending=0;
   if(!was_reset)begin reset_ledger();epoch=epoch+1;last_abort=0;last_status=-1;render_round=0;words_written=0;$display("G2_RESET_ASSERT epoch=%0d edge=%0d",epoch,edge_no);end
  end else begin
   if(was_reset)begin $display("G2_RESET_RELEASE epoch=%0d edge=%0d qualified=1000000",epoch,edge_no);end
   if(dut.u_CPU.commit_valid && dut.u_CPU.WB_pc==0)begin
    if(dut.u_CPU.WB_instruction!==START_WORD)fail("G2_IMAGE");boots=boots+1;$display("G2_BOOT epoch=%0d edge=%0d word=%08x",epoch,edge_no,dut.u_CPU.WB_instruction);
   end
   if((LANE==1 || LANE==2) && errors && dut.u_CPU.commit_valid && (dut.u_CPU.WB_pc==FAULT_PC || (dut.u_CPU.WB_pc>=YOUNGER_PC && dut.u_CPU.WB_pc<YOUNGER_PC+16)))fail("G2_FAULT");
   bank=dut.U_VRAM.vram1_we?1:0;wa=dut.U_VRAM.write_addr;wd=dut.U_VRAM.write_data;
   if(!env_lock)begin
    $display("G2_LOCK_LOW epoch=%0d edge=%0d we=%0d%0d hreset=%0d",epoch,edge_no,dut.U_VRAM.vram1_we,dut.U_VRAM.vram0_we,dut.HRESETn);
    if(dut.U_VRAM.vram0_we || dut.U_VRAM.vram1_we || dut.HRESETn!==1)fail("G2_PLL");
   end
   if(pending && route(pa)==3 && !dut.HREADY)begin apb_wait=apb_wait+1;$display("G2_APB_WAIT edge=%0d id=%0d route=%0d active=%0d",edge_no,id,dut.HSEL_APB_d?3:0,active);if(!dut.HSEL_APB_d)fail("G2_BUS");end
   if(pending && dut.HRESP==1)begin
    $display("G2_ERROR epoch=%0d edge=%0d id=%0d addr=%08x pc=%08x ready=%0d resp=%0d hold=%0d we=%0d%0d clear_we=%0d",epoch,edge_no,id,pa,dut.u_CPU.MEM_pc,dut.HREADY,dut.HRESP,dut.u_CPU.bus_wait_hold,dut.U_VRAM.vram1_we,dut.U_VRAM.vram0_we,dut.U_VRAM.clear_we);
    if(!active || dut.u_CPU.MEM_pc!==FAULT_PC || dut.U_VRAM.vram0_we || dut.U_VRAM.vram1_we || !dut.HSEL_VRAM_d)fail("G2_FAULT");
    if(error_step==0)begin if(dut.HREADY!==0 || dut.u_CPU.bus_wait_hold!==1)fail("G2_FAULT");error_step=1;error_edge=edge_no;end
    else begin if(error_step!=1 || dut.HREADY!==1 || edge_no!=error_edge+1 || dut.u_CPU.bus_wait_hold!==0)fail("G2_FAULT");error_step=2;errors=errors+1;end
   end
   if(dut.U_VRAM.vram0_we || dut.U_VRAM.vram1_we)begin
    if(dut.U_VRAM.vram0_we && dut.U_VRAM.vram1_we)fail("G2_BANK");
    if(bank==front || wa>=9600)fail("G2_BANK");
    if(pending && pw && pa>=32'h20000000 && pa<32'h20009600 && dut.HREADY && dut.HRESP==0)begin
     if(active || bank!=1-hfront || wa!=(pa-32'h20000000)/4 || wd!==dut.HWDATA)fail("G2_BANK");
     expected_word=wa^(render_round==0?32'h80000001:32'h55aa55aa);
     if(wa!=words_written || wd!==expected_word)fail("G2_IMAGE");
     words_written=words_written+1;
     if(words_written==9600)begin words_written=0;render_round=render_round+1;end
     $display("G2_CPU_WRITE epoch=%0d edge=%0d id=%0d addr=%0d bank=%0d data=%08x",epoch,edge_no,id,wa,bank,wd);
    end else begin
     if(!active || !(command&2) || await_commit || bank!=target || wa!=clear_count || wd!==0)fail("G2_COMPLETION");
     clearing=1;clear_count=clear_count+1;
     $display("G2_CLEAR epoch=%0d edge=%0d op=%0d addr=%0d bank=%0d data=%08x",epoch,edge_no,last_command_id,wa,bank,wd);
    end
    if(bank)memory1[wa]=wd;else memory0[wa]=wd;
   end else if(pending && pw && pa>=32'h20000000 && pa<32'h20009600 && dut.HREADY && dut.HRESP==0)fail("G2_BANK");
   if(pending && dut.HREADY)begin
    if(route(pa)!=(dut.HSEL_MEM_d?1:(dut.HSEL_VRAM_d?2:(dut.HSEL_APB_d?3:0))))fail("G2_BUS");
    if(ps!=2)fail("G2_BUS");
    if(pw || pa!=32'h20010000 || dut.HRDATA!=last_status) $display("G2_FINAL epoch=%0d edge=%0d id=%0d addr=%08x write=%0d data=%08x rdata=%08x resp=%0d route=%0d",epoch,edge_no,id,pa,pw,dut.HWDATA,dut.HRDATA,dut.HRESP,route(pa));
    if(!pw && pa==32'h20010000)last_status=dut.HRDATA;
    if(dut.HRESP==0 && pw)begin
     if(pa==32'h20010004 && dut.HWDATA[1:0]!=0)begin
      if(active)fail("G2_CAUSALITY");commands=commands+1;last_command_id=id;command=dut.HWDATA&3;active=1;clear_count=0;await_commit=(command&1)!=0;target=1-hfront;
      $display("G2_COMMAND epoch=%0d edge=%0d op=%0d command=%0d front=%0d target=%0d",epoch,edge_no,id,command,front,target);
     end
     if(pa==32'h20010000)begin pre_status={27'b0,dut.U_VRAM.domain_ready,dut.U_VRAM.operation_abort_sticky,dut.U_VRAM.operation_busy,dut.U_VRAM.operation_done_sticky,dut.U_VRAM.vsync_sticky};w1c_mask=dut.HWDATA&11;w1c=1;end
     if(route(pa)==1)begin
      dmem=dmem+1;
      if(dut.u_memory.u_bram.wren!==1 || dut.u_memory.u_bram.wraddress!==((pa-32'h10000000)>>2) || dut.u_memory.u_bram.byteena_a!==4'hf || dut.u_memory.u_bram.data!==dut.HWDATA)fail("G2_DMEM");
      $display("G2_DMEM epoch=%0d edge=%0d addr=%08x data=%08x we=%0d word=%0d mask=%0d",epoch,edge_no,pa,dut.HWDATA,dut.u_memory.u_bram.wren,dut.u_memory.u_bram.wraddress,dut.u_memory.u_bram.byteena_a);
      if(pa==32'h10000004)begin if(dut.HWDATA!==7)fail("G2_FAULT");diag_cause=diag_cause+1;end
      if(pa==32'h10000008)begin if(dut.HWDATA!==FAULT_PC)fail("G2_FAULT");diag_pc=diag_pc+1;end
      if(pa==32'h1000000c)fail("G2_FAULT");
      if(pa==32'h10000000)begin
       if(dut.HWDATA!==((LANE==1 || LANE==2)?32'h47324641:32'h47324f4b))fail("G2_IMAGE");signature=signature+1;
      end
     end
    end
   end
   if(dut.HREADY)begin pending=dut.HTRANS[1] && dut.HRESP!=1;if(pending)begin id=id+1;pa=dut.HADDR;pw=dut.HWRITE;ps=dut.HSIZE;end end
  end
  was_reset=reset_now;
  #0.003;
  if(dut.HRESETn!==reset_ref.released || dut.U_VRAM.pclk_25!==env_c0 || dut.U_VRAM.vga_pll_locked!==env_lock)fail("G2_RESET");
  if(dut.HRESETn)begin
   if(dut.U_VRAM.request_toggle_h!=req_before)begin
    if(!active || !(command&1) || req_before==dut.U_VRAM.request_toggle_h)fail("G2_CAUSALITY");
    request_events=request_events+1;$display("G2_REQUEST epoch=%0d edge=%0d op=%0d value=%0d",epoch,edge_no,last_command_id,dut.U_VRAM.request_toggle_h);req_before=dut.U_VRAM.request_toggle_h;
   end
   if(dut.U_VRAM.ack_toggle_p!=ack_before)begin
    if(!active || await_commit || edge_no<commit_edge || !(command&1))fail("G2_CAUSALITY");
    acks=acks+1;ack_events=ack_events+1;$display("G2_ACK epoch=%0d edge=%0d op=%0d value=%0d",epoch,edge_no,last_command_id,dut.U_VRAM.ack_toggle_p);ack_before=dut.U_VRAM.ack_toggle_p;
   end
   if(dut.U_VRAM.front_bank_h!=hbank_before)begin
    if(!active || await_commit || acks<commits)fail("G2_CAUSALITY");
    hfront=front;hbank_before=hfront;owners=owners+1;if(command&2)target=1-front;
    $display("G2_OWNER epoch=%0d edge=%0d op=%0d front=%0d target=%0d",epoch,edge_no,last_command_id,hfront,target);
   end
   if(dut.U_VRAM.operation_done_sticky && !last_done)begin
    if(!active || await_commit || ((command&2) && clear_count!=9600) || ((command&1) && hfront!=front))fail("G2_COMPLETION");
    active=0;dones=dones+1;done_edge=edge_no;$display("G2_DONE epoch=%0d edge=%0d op=%0d clear=%0d front=%0d",epoch,edge_no,last_command_id,clear_count,front);
   end
   if(dut.U_VRAM.operation_abort_sticky && !last_abort)begin
    if(LANE!=4 || !injected || canceled!=1)fail("G2_RECOVERY");aborts=aborts+1;$display("G2_ABORT epoch=%0d edge=%0d canceled=%0d done=%0d",epoch,edge_no,canceled,dut.U_VRAM.operation_done_sticky);
   end
   if(injected && !dut.U_VRAM.domain_ready)ready_drop=ready_drop+1;
   if(!env_lock && dut.U_VRAM.operation_done_sticky)fail("G2_PLL");
   if(w1c)begin
    post_status={27'b0,dut.U_VRAM.domain_ready,dut.U_VRAM.operation_abort_sticky,dut.U_VRAM.operation_busy,dut.U_VRAM.operation_done_sticky,dut.U_VRAM.vsync_sticky};
    $display("G2_W1C epoch=%0d edge=%0d mask=%0d before=%0d after=%0d",epoch,edge_no,w1c_mask,pre_status,post_status);
    if(post_status[1]!==((pre_status[1] && !w1c_mask[1]) || done_edge==edge_no) || post_status[3]!==((pre_status[3] && !w1c_mask[3]) || (aborts && !last_abort)))fail("G2_W1C");
   end
   last_done=dut.U_VRAM.operation_done_sticky;last_abort=dut.U_VRAM.operation_abort_sticky;
   if(signature && !active && !pending && edge_no>done_edge+10)begin
    if((LANE==0 && dones==3 && pixels>=18 && frames>=3) || ((LANE==1 || LANE==2) && dones==1) || (LANE==3 && dones==1 && key_injected && pixels>=6) || (LANE==4 && dones==1 && injected && p4_recovery_frame==frames && p4_recovery_pixels==6'b111111))begin
     if((LANE==1 || LANE==2) && (errors!=1 || error_step!=2 || diag_cause!=1 || diag_pc!=1))fail("G2_REACH");
     if(LANE==4 && (aborts!=1 || !ready_drop || canceled!=1 || dut.HRESETn!==1))fail("G2_REACH");
     if(LANE==3 && (canceled!=1 || boots!=2 || commands!=2))fail("G2_REACH");
     $display("G2_SUMMARY PASS lane=%0d epoch=%0d commands=%0d commits=%0d acks=%0d owners=%0d dones=%0d canceled=%0d aborts=%0d boots=%0d pixels=%0d apb_wait=%0d errors=%0d dmem=%0d",LANE,epoch,commands,commits,acks,owners,dones,canceled,aborts,boots,pixels,apb_wait,errors,dmem);$finish;
    end
   end
  end
 end
endmodule
