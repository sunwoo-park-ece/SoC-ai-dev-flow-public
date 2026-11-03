`timescale 1ns/1ps
module tb_p13_05_cpu_fault;
 parameter IMEM_FILE="";
 parameter DMEM_FILE="";
 reg clk=0;
 reg [1:0] KEY=2'b10;
 wire [15:0] GPIO_IO;
 wire [9:0] LEDR;
 wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
 wire CS,SCLK,SDI,HS,VS,LTX,UTX;
 wire [3:0] VR,VG,VB;
 AMBA_SoC_TOP dut(.clk(clk),.KEY(KEY),.SW(10'b0),.GPIO_IO(GPIO_IO),
 .LEDR(LEDR),.HEX0(HEX0),.HEX1(HEX1),.HEX2(HEX2),.HEX3(HEX3),.HEX4(HEX4),.HEX5(HEX5),
 .G_SENSOR_CS_N(CS),.G_SENSOR_SCLK(SCLK),.G_SENSOR_SDI(SDI),.VGA_R(VR),.VGA_G(VG),.VGA_B(VB),.VGA_HS(HS),.VGA_VS(VS),.lora_tx(LTX),.uart_tx(UTX),.G_SENSOR_INT(2'b0),.G_SENSOR_SDO(1'b0),.lora_rx(1'b1),.lora_aux(1'b0),.uart_rx(1'b1));
 defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE=IMEM_FILE;
 defparam dut.u_memory.u_bram.INIT_FILE=DMEM_FILE;
 always #10 clk=~clk;
 reg completed=0;
 integer cyc=0,release_at=0,reset_cycles=0,accepted=0,first_errors=0,final_errors=0,first_error_cycle=0;
 reg released=0,start_seen=0,main_seen=0;
 reg [31:0] main_pc,fault_pc,younger_pc,end_pc,trap_pc,target_addr,expected_cause;
 integer expected_size,is_store,misaligned;
 initial begin
 if (!$value$plusargs("MAIN_PC=%h",main_pc))$fatal(1,"MAIN_PC");
 if (!$value$plusargs("FAULT_PC=%h",fault_pc))$fatal(1,"FAULT_PC");
 if (!$value$plusargs("YOUNGER_PC=%h",younger_pc))$fatal(1,"YOUNGER_PC");
 if (!$value$plusargs("END_PC=%h",end_pc))$fatal(1,"END_PC");
 if (!$value$plusargs("TRAP_PC=%h",trap_pc))$fatal(1,"TRAP_PC");
 if (!$value$plusargs("TARGET=%h",target_addr))$fatal(1,"TARGET");
 if (!$value$plusargs("CAUSE=%d",expected_cause))$fatal(1,"CAUSE");
 if (!$value$plusargs("SIZE=%d",expected_size))$fatal(1,"SIZE");
 if (!$value$plusargs("STORE=%d",is_store))$fatal(1,"STORE");
 if (!$value$plusargs("MISALIGNED=%d",misaligned))$fatal(1,"MISALIGNED");
 repeat(10)@(negedge clk);KEY[0]=1;release_at=cyc;
 end
 always @(posedge clk) begin
 cyc=cyc+1;
 if (!KEY[0] && dut.HRESETn!==0)$fatal(1,"RESET_ASSERT");
 if(KEY[0] && !released && dut.HRESETn===1) begin
 reset_cycles=cyc-release_at;
 if(reset_cycles<1000002 || reset_cycles>1000005)$fatal(1,"RESET_QUALIFICATION");
 released=1;$display("CHECK RESET_QUALIFICATION cycles=%0d",reset_cycles);
 end
 if(released)begin
 if(dut.PSEL[4]!==0)$fatal(1,"FAULT_AES_PSEL_SIDE_EFFECT");
 if(dut.u_memory.u_bram.wren && dut.u_memory.u_bram.wraddress==0)$fatal(1,"FAULT_YOUNGER_STORE_SIDE_EFFECT");
 if(dut.HREADY && dut.HTRANS[1] && dut.HADDR[31:16]==16'h4004)begin
 accepted=accepted+1;
 $display("EVENT FAULT_ADDRESS time=%0t address=%h size=%h write=%0d",$time,dut.HADDR,dut.HSIZE,dut.HWRITE);
 if(misaligned || dut.HADDR!==target_addr || dut.HSIZE!==expected_size[2:0] || dut.HWRITE!==is_store[0])$fatal(1,"FAULT_ADDRESS_CLASS");
 end
 if(dut.HRESP===2'b01)begin
 if(dut.HREADY===0)begin first_errors=first_errors+1;first_error_cycle=cyc;$display("EVENT ERROR_FIRST time=%0t",$time);end
 else if(dut.HREADY===1)begin
 final_errors=final_errors+1;
 if(first_errors!=1 || final_errors!=1 || cyc!=first_error_cycle+1)$fatal(1,"ERROR_TWO_PHASE");
 $display("EVENT ERROR_FINAL time=%0t",$time);
 end else $fatal(1,"ERROR_READY_X");
 end
 if(dut.u_CPU.gpr_commit && dut.u_CPU.WB_pc===fault_pc)$fatal(1,"FAULT_LOAD_WRITEBACK");
 if(dut.u_CPU.commit_valid)begin
 if(dut.u_CPU.WB_pc===0)begin start_seen=1;$display("CHECK START_RETIRE cycle=%0d",cyc);end
 if(dut.u_CPU.WB_pc===main_pc)begin main_seen=1;$display("CHECK MAIN_RETIRE cycle=%0d",cyc);end
 if(dut.u_CPU.WB_pc===fault_pc || (dut.u_CPU.WB_pc>=younger_pc && dut.u_CPU.WB_pc<=end_pc))$fatal(1,"FAULT_OR_YOUNGER_RETIRE");
 if(dut.u_CPU.WB_pc===trap_pc)begin
 if(!start_seen || !main_seen)$fatal(1,"FAULT_BOOT_CHAIN");
 if(dut.u_CPU.csr_file.mcause!==expected_cause || dut.u_CPU.csr_file.mepc!==fault_pc)$fatal(1,"FAULT_CAUSE_PC");
 if(misaligned)begin if(accepted!=0 || first_errors!=0 || final_errors!=0)$fatal(1,"PREBUS_FAULT_SIDE_EFFECT");end
 else if(accepted!=1 || first_errors!=1 || final_errors!=1)$fatal(1,"BRIDGE_FAULT_COVERAGE");
 completed=1;$display("CHECK FAULT_PASS cycles=%0d cause=%0d mepc=%h accepted=%0d first=%0d final=%0d",cyc,dut.u_CPU.csr_file.mcause,dut.u_CPU.csr_file.mepc,accepted,first_errors,final_errors);$finish;
 end
 end
 end
 if(cyc>=10000000)$fatal(1,"FAULT_SIM_BUDGET");
 end
endmodule
