`timescale 1ns/1ps
module tb_p13_05_cpu_e2e;
 parameter IMEM_FILE="";
 parameter DMEM_FILE="";
 parameter RECOVERY=0;
 reg [9:0] SW=0;
 integer epoch=0;
 reg reset_requested=0;
 reg [31:0] recovery_addr;
 reg clk=0;
 reg [1:0] KEY=2'b10;
 wire [15:0] GPIO_IO;
 wire [9:0] LEDR;
 wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
 wire CS,SCLK,SDI,HS,VS,LTX,UTX;
 wire [3:0] VR,VG,VB;
 AMBA_SoC_TOP dut(.clk(clk),.KEY(KEY),.SW(SW),.GPIO_IO(GPIO_IO),
 .LEDR(LEDR),.HEX0(HEX0),.HEX1(HEX1),.HEX2(HEX2),.HEX3(HEX3),.HEX4(HEX4),.HEX5(HEX5),
 .G_SENSOR_CS_N(CS),.G_SENSOR_SCLK(SCLK),.G_SENSOR_SDI(SDI),.VGA_R(VR),.VGA_G(VG),.VGA_B(VB),.VGA_HS(HS),.VGA_VS(VS),.lora_tx(LTX),.uart_tx(UTX),.G_SENSOR_INT(2'b0),.G_SENSOR_SDO(1'b0),.lora_rx(1'b1),.lora_aux(1'b0),.uart_rx(1'b1));
 defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE=IMEM_FILE;
 defparam dut.u_memory.u_bram.INIT_FILE=DMEM_FILE;
 always #10 clk=~clk;
 p13_05_contract_checker check_bus(.status(dut.u_apb_aes_gcm.status_wire),.clk(clk),.reset_n(dut.HRESETn),.haddr(dut.HADDR),.htrans(dut.HTRANS),.hsize(dut.HSIZE),.hwrite(dut.HWRITE),.hwdata(dut.HWDATA),.hrdata(dut.HRDATA),.hready(dut.HREADY),.hresp(dut.HRESP),.psel(dut.PSEL),.penable(dut.PENABLE),.paddr(dut.PADDR),.pwrite(dut.PWRITE),.pwdata(dut.PWDATA),.prdata(dut.PRDATA),.pready(dut.APB_SLAVE_PREADY));
 reg seen_release=0,seen_start=0,seen_main=0;
 reg completed=0;
 integer case_id=0,j;
 reg [31:0] case_addr,done_addr,result_addr,out_addr,tag_addr,diag_addr;
 reg [7:0] bv;
 reg old_done=0,old_maint=0;
 function [7:0] byte_at;
 input [31:0] a;
 begin byte_at=(dut.u_memory.u_bram.words[(a-32'h10000000)>>2] >> (8*a[1:0])); end
 endfunction
 function [31:0] word_at;
 input [31:0] a;
 begin word_at=dut.u_memory.u_bram.words[(a-32'h10000000)>>2]; end
 endfunction
 initial begin
 if (RECOVERY && !$value$plusargs("REC_ADDR=%h",recovery_addr)) $fatal(1,"REC_ADDR");
 if (!$value$plusargs("CASE_ADDR=%h",case_addr)) $fatal(1,"CASE_ADDR");
 if (!$value$plusargs("DONE_ADDR=%h",done_addr)) $fatal(1,"DONE_ADDR");
 if (!$value$plusargs("RESULT_ADDR=%h",result_addr)) $fatal(1,"RESULT_ADDR");
 if (!$value$plusargs("OUT_ADDR=%h",out_addr)) $fatal(1,"OUT_ADDR");
 if (!$value$plusargs("TAG_ADDR=%h",tag_addr)) $fatal(1,"TAG_ADDR");
 if (!$value$plusargs("DIAG_ADDR=%h",diag_addr)) $fatal(1,"DIAG_ADDR");
 end
 always @(posedge clk) if (seen_release) begin
 if ((^dut.u_apb_aes_gcm.status_wire)===1'bx) $fatal(1,"POST_RESET_STATUS_X");
 if (dut.u_apb_aes_gcm.status_wire[1] && !old_done)
 $display("EVENT TERMINAL time=%0t cycle=%0d case=%0d status=%h",$time,cycles,case_id,dut.u_apb_aes_gcm.status_wire);
 if(old_maint && !dut.u_apb_aes_gcm.status_wire[13]) $display("EVENT MAINT_DONE time=%0t cycle=%0d case=%0d",$time,cycles,case_id);
 old_maint=dut.u_apb_aes_gcm.status_wire[13];
 if (dut.u_apb_aes_gcm.core_key_word_val_reg!=0 || dut.u_apb_aes_gcm.core_iv_val_reg || dut.u_apb_aes_gcm.core_ghash_pkt_val_reg)
 $display("EVENT CORE cycle=%0d case=%0d",cycles,case_id);
 old_done=dut.u_apb_aes_gcm.status_wire[1];
 if (dut.u_memory.u_bram.wren) begin
 if(RECOVERY && (32'h10000000+4*dut.u_memory.u_bram.wraddress)===recovery_addr && dut.u_memory.u_bram.data===0 && dut.u_memory.u_bram.byteena_a===4'hf)
 $display("CHECK BSS_CLEAR epoch=%0d cycle=%0d",epoch,cycles);
 if ((32'h10000000+4*dut.u_memory.u_bram.wraddress)===case_addr) begin
 case_id=dut.u_memory.u_bram.data;
 $display("EVENT CASE cycle=%0d id=%0d",cycles,case_id);
 end
 if ((32'h10000000+4*dut.u_memory.u_bram.wraddress)===done_addr && dut.u_memory.u_bram.data!=0) begin
 $write("EVENT RESULT cycle=%0d case=%0d rc=%0d status=%h polls=%0d maintenance=%0d recovery=%0d start=%0d out=",cycles,case_id,word_at(result_addr),word_at(diag_addr),word_at(diag_addr+4),word_at(diag_addr+8),word_at(diag_addr+12),word_at(diag_addr+16));
 for(j=0;j<20;j=j+1)$write("%02x",byte_at(out_addr+j));
 $write(" tag=");for(j=0;j<20;j=j+1)$write("%02x",byte_at(tag_addr+j));$write("\n");
 end
 if ((32'h10000000+4*dut.u_memory.u_bram.wraddress)>=out_addr && (32'h10000000+4*dut.u_memory.u_bram.wraddress)<out_addr+20)
 $display("EVENT CALLER_WRITE cycle=%0d case=%0d addr=%h data=%h lanes=%h status=%h",cycles,case_id,32'h10000000+4*dut.u_memory.u_bram.wraddress,dut.u_memory.u_bram.data,dut.u_memory.u_bram.byteena_a,dut.u_apb_aes_gcm.status_wire);
 end
 end
 integer cycles=0, release_edge=0, reset_cycles=0;
 reg [31:0] main_pc,sig_addr,trap_pc;
 initial begin
  if (!$value$plusargs("MAIN_PC=%h",main_pc)) $fatal(1,"MISSING_MAIN_PC");
  if (!$value$plusargs("SIG_ADDR=%h",sig_addr)) $fatal(1,"MISSING_SIG_ADDR");
  if (!$value$plusargs("TRAP_PC=%h",trap_pc)) $fatal(1,"MISSING_TRAP_PC");
  repeat(10) @(negedge clk);
  KEY[0]=1;
  release_edge=cycles;
 end
 always @(posedge clk) begin
  cycles=cycles+1;
  if (!KEY[0] && dut.HRESETn !== 0) $fatal(1,"RESET_ASSERT");
  if (KEY[0] && !seen_release) begin
   if (dut.HRESETn === 1) begin
    reset_cycles=cycles-release_edge;
    if (reset_cycles < 1000002 || reset_cycles > 1000005) $fatal(1,"RESET_QUALIFICATION cycles=%0d",reset_cycles);
    seen_release=1;
    $display("CHECK RESET_QUALIFICATION cycles=%0d time=%0t",reset_cycles,$time);
   end
  end
  if (seen_release && dut.u_CPU.commit_valid) begin
   if (dut.u_CPU.WB_pc===0) begin seen_start=1; $display("CHECK START_RETIRE cycle=%0d",cycles); end
   if (dut.u_CPU.WB_pc===main_pc) begin
    if(RECOVERY && word_at(recovery_addr)!==0)$fatal(1,"FRESH_BSS_RECOVERY_NOT_CLEAR");
    seen_main=1; $display("CHECK MAIN_RETIRE cycle=%0d pc=%h",cycles,main_pc); end
   if (dut.u_CPU.WB_pc===trap_pc) $fatal(1,"UNEXPECTED_TRAP cause=%h mepc=%h",dut.u_CPU.csr_file.mcause,dut.u_CPU.csr_file.mepc);
  end
  if (seen_release && dut.u_memory.u_bram.wren && dut.u_memory.u_bram.wraddress===((sig_addr-32'h10000000)>>2)) begin
   $display("WITNESS SIG_WRITE cycle=%0d data=%h lanes=%h",cycles,dut.u_memory.u_bram.data,dut.u_memory.u_bram.byteena_a);
   if (dut.u_memory.u_bram.data===32'h50313342 && dut.u_memory.u_bram.byteena_a===4'hf) begin
    if (!seen_start || !seen_main) $fatal(1,"BOOT_CHAIN_MISSING");
    if (RECOVERY && epoch==0) begin
     reset_requested=1;$display("CHECK OLD_SESSION_COMPLETE epoch=0");
    end else begin
    completed=1;
    $display("CHECK BOOT_STORE_PASS cycles=%0d reset_cycles=%0d",cycles,reset_cycles);
    $finish;
    end
   end
  end
  if (cycles>=10000000) $fatal(1,"B0_SIM_BUDGET");
 end
initial if(RECOVERY) begin
 wait(reset_requested);
 @(negedge clk);KEY[0]=0;SW=1;epoch=1;seen_release=0;seen_start=0;seen_main=0;old_done=0;old_maint=0;case_id=0;
 $display("EVENT RESET_EPOCH epoch=1 time=%0t",$time);
 repeat(10)@(negedge clk);release_edge=cycles;KEY[0]=1;
end
endmodule
