`timescale 1ns/1ps
module tb;
  reg clk=0;always #10 clk=~clk;
  reg [1:0] KEY=2'b10;
  reg [9:0] SW=0;
  reg [2:1] G_SENSOR_INT=0;
  reg G_SENSOR_SDO=0,lora_rx=1,lora_aux=0,uart_rx=1;
  wire [9:0] LEDR;
  wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
  wire [3:0] VGA_R,VGA_G,VGA_B;
  wire VGA_HS,VGA_VS,lora_tx,uart_tx,G_SENSOR_CS_N,G_SENSOR_SCLK,G_SENSOR_SDI;
  wire [15:0] GPIO_IO;
  AMBA_SoC_TOP dut(.*);
  defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE="program.hex";
  integer fd,i,ticks=0,accepts=0;
  reg reset_check=0;
  always @(posedge clk) begin
    ticks=ticks+1;
    if(dut.PRESETN_SYS && dut.u_uart1_pc.tx_accept) accepts=accepts+1;
    if(reset_check && (dut.u_memory.u_bram.wren!==0 || dut.PSEL!==0 || dut.u_uart1_pc.tx_busy!==0)) $fatal(1,"RESET_QUIET");
    if(ticks>2100000) $fatal(1,"RESET_RECOVERY_TIMEOUT");
  end
  task dump(input integer tag);
    begin
      for(i=0;i<32;i=i+1)$fdisplay(fd,"%0d %0d %h",tag,i,dut.u_memory.u_bram.words[i]);
    end
  endtask
  initial begin
    fd=$fopen("reset.txt","w");
    repeat(5)@(negedge clk);KEY[0]=1;
    wait(dut.PRESETN_SYS);
    wait(dut.PSEL[6] && dut.PENABLE && dut.PADDR==32'h40060000 && !dut.APB_SLAVE_PREADY);
    repeat(10)@(negedge clk);
    if(dut.HREADY!==0 || accepts!=1)$fatal(1,"RESET_WAIT_NOT_REACHED");
    dump(0);KEY[0]=0;
    repeat(2)@(negedge clk);reset_check=1;
    repeat(5)@(negedge clk);dump(1);reset_check=0;KEY[0]=1;
    wait(dut.PRESETN_SYS);@(negedge clk);dump(2);
    if(dut.u_memory.u_bram.wren!==0 || dut.u_uart1_pc.tx_busy!==0 || accepts!=1)$fatal(1,"RESET_CANCEL_OR_RECOVERY");
    $fdisplay(fd,"S %0d %0d",ticks,accepts);$fclose(fd);
    $display("TARGET_COMPLETE RESET_STALL_CANCEL_AND_NATURAL_RECOVERY ticks=%0d",ticks);$finish;
  end
endmodule
