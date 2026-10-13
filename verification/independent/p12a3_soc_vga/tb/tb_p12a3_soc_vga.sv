`timescale 1ns/1ps
module tb_p12a3_soc_vga;
 parameter IMEM_FILE="";
 parameter integer FAULT_CASE=0;
 parameter [31:0] FAULT_PC=0, YOUNGER_PC=0, TERMINAL_PC=0,TRAP_PC=0,START_INSTRUCTION=0;
 reg clk=0; always #10 clk=~clk;
 reg [1:0] key=2'b10;
 AMBA_SoC_TOP dut(.clk(clk),.KEY(key),.SW(10'b0),.G_SENSOR_INT(2'b0),
 .G_SENSOR_SDO(1'b0),.lora_rx(1'b1),.lora_aux(1'b1),.uart_rx(1'b1));
 defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE=IMEM_FILE;
 p12a3_soc_vga_ref ref_model(clk,key[0],);
 p12a3_soc_vga_observer #(.FAULT_CASE(FAULT_CASE),.FAULT_PC(FAULT_PC),
 .YOUNGER_PC(YOUNGER_PC),.TERMINAL_PC(TERMINAL_PC),.TRAP_PC(TRAP_PC),.START_INSTRUCTION(START_INSTRUCTION)) observer();
 initial begin
  $display("G1_IMAGE static=%s fault=%0d pc=%08x",IMEM_FILE,FAULT_CASE,FAULT_PC);
  if (IMEM_FILE=="") $fatal(1,"FAIL_G1_IMAGE");
  repeat(5) @(negedge clk); #5 key[0]=1;
  #40000000; $fatal(1,"FAIL_G1_REACH timeout");
 end
endmodule
