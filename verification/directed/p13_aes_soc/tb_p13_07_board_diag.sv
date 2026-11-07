`timescale 1ns/1ps
// Production CPU/bridge/wrapper/VHDL + real UART serializer. Only external
// clock/KEY stimuli; memory INIT_FILE parameters select the actual FW image.
module tb_p13_07_board_diag;
 parameter IMEM_FILE="", DMEM_FILE="";
 reg clk=0;
 reg [1:0] KEY=2'b10;
 wire [15:0] GPIO_IO;
 wire [9:0] LEDR;
 wire [6:0] H0,H1,H2,H3,H4,H5;
 wire CS,SCLK,SDI,HS,VS,LTX,UTX;
 wire [3:0] VR,VG,VB;
 AMBA_SoC_TOP dut(.clk(clk),.KEY(KEY),.SW(10'b0),.GPIO_IO(GPIO_IO),
 .LEDR(LEDR),.HEX0(H0),.HEX1(H1),.HEX2(H2),.HEX3(H3),.HEX4(H4),.HEX5(H5),
 .G_SENSOR_CS_N(CS),.G_SENSOR_SCLK(SCLK),.G_SENSOR_SDI(SDI),
 .VGA_R(VR),.VGA_G(VG),.VGA_B(VB),.VGA_HS(HS),.VGA_VS(VS),
 .lora_tx(LTX),.uart_tx(UTX),.G_SENSOR_INT(2'b0),.G_SENSOR_SDO(1'b0),
 .lora_rx(1'b1),.lora_aux(1'b0),.uart_rx(1'b1));
 defparam dut.u_CPU.if_id_register.u_IMEM.INIT_FILE=IMEM_FILE;
 defparam dut.u_memory.u_bram.INIT_FILE=DMEM_FILE;
 always #10 clk=~clk;
 integer fd,trace_fd,epoch=0,cycles=0,release_cycle=0,release_at=0,starts=0;
 integer bit_index,received=0;
 reg [7:0] ch;
 string line="";
 reg session_complete=0,seen_release=0,completed=0;
 reg [31:0] output_addr,trap_pc;
 reg bad_tag=0,auth_window=0;
 initial begin
  if(!$value$plusargs("OUTPUT_ADDR=%h",output_addr))$fatal(1,"OUTPUT_ADDR");
  if(!$value$plusargs("TRAP_PC=%h",trap_pc))$fatal(1,"TRAP_PC");
  fd=$fopen("uart0.log","w");trace_fd=$fopen("bus-caller.log","w");
  if(!fd || !trace_fd)$fatal(1,"CAPTURE_OPEN");
  repeat(10)@(negedge clk);release_at=cycles;KEY[0]=1;
  wait(session_complete);
  // Legal external reset, new BSP/.bss driver session; no fake runtime ACK.
  @(negedge clk);KEY[0]=0;epoch=1;seen_release=0;auth_window=0;bad_tag=0;
  repeat(10)@(negedge clk);release_at=cycles;KEY[0]=1;
  session_complete=0;line="";fd=$fopen("uart1.log","w");
  if(!fd)$fatal(1,"CAPTURE_REBOOT_OPEN");
  wait(session_complete);
  completed=1;$fclose(trace_fd);$display("H0_SERIAL_COMPLETE epochs=2 starts=%0d bytes=%0d",starts,received);$finish;
 end
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>30000000)$fatal(1,"SERIAL_WATCHDOG");
  if(!KEY[0] && dut.HRESETn!==0)$fatal(1,"RESET_ASSERT");
  if(KEY[0] && !seen_release && dut.HRESETn===1)begin
   release_cycle=cycles-release_at;
   if(release_cycle<1000002 || release_cycle>1000005)$fatal(1,"RESET_QUALIFICATION");
   seen_release=1;$fdisplay(trace_fd,"RESET epoch=%0d qualification=%0d",epoch,release_cycle);
  end
  if(seen_release)begin
   if((^dut.u_apb_aes_gcm.status_wire)===1'bx)$fatal(1,"STATUS_X");
   if(dut.u_CPU.commit_valid && dut.u_CPU.WB_pc===trap_pc)$fatal(1,"CPU_TRAP");
   if(dut.PSEL[4] && dut.PENABLE && dut.APB_SLAVE_PREADY)begin
    $fdisplay(trace_fd,"AES epoch=%0d cycle=%0d wr=%b addr=%h wdata=%h rdata=%h",epoch,cycles,dut.PWRITE,dut.PADDR,dut.PWDATA,dut.PRDATA);
    if(dut.PWRITE && dut.PADDR==32'h40040050)bad_tag=(dut.PWDATA==32'hb4573f54);
    if(dut.PWRITE && dut.PADDR==32'h4004000c && (dut.PWDATA==1 || dut.PWDATA==3))begin
     starts=starts+1;auth_window=bad_tag && dut.PWDATA==3;
    end
   end
   if(dut.PSEL[6] && dut.PENABLE && dut.APB_SLAVE_PREADY && dut.PWRITE && dut.PADDR==32'h40060000)auth_window=0;
   if(dut.u_memory.u_bram.wren &&
      (32'h10000000+4*dut.u_memory.u_bram.wraddress)>=output_addr &&
      (32'h10000000+4*dut.u_memory.u_bram.wraddress)<output_addr+16)begin
    $fdisplay(trace_fd,"CALLER epoch=%0d cycle=%0d auth=%b data=%h lanes=%h status=%h",epoch,cycles,auth_window,dut.u_memory.u_bram.data,dut.u_memory.u_bram.byteena_a,dut.u_apb_aes_gcm.status_wire);
    if(auth_window && ((dut.u_memory.u_bram.byteena_a[0] && dut.u_memory.u_bram.data[7:0]!=0) ||
      (dut.u_memory.u_bram.byteena_a[1] && dut.u_memory.u_bram.data[15:8]!=0) ||
      (dut.u_memory.u_bram.byteena_a[2] && dut.u_memory.u_bram.data[23:16]!=0) ||
      (dut.u_memory.u_bram.byteena_a[3] && dut.u_memory.u_bram.data[31:24]!=0)))$fatal(1,"CALLER_AUTH_RELEASE");
   end
  end
 end
 // Sample UTX on the physical serial line at the center of every bit.
 initial forever begin
  @(negedge UTX);
  if(seen_release && !session_complete)begin
   repeat(217)@(posedge clk);
   if(UTX!==0)$fatal(1,"UART_START");
   for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
    repeat(434)@(posedge clk);
    if(UTX!==0 && UTX!==1)$fatal(1,"UART_DATA_X");
    ch[bit_index]=UTX;
   end
   repeat(434)@(posedge clk);if(UTX!==1)$fatal(1,"UART_STOP");
   $fwrite(fd,"%c",ch);$fflush(fd);received=received+1;
   if(ch!=13)begin
    if(ch==10)begin
     if(line=="END complete=1")begin $fclose(fd);session_complete=1;end
     if(line=="END complete=0")$fatal(1,"APP_REPORTED_FAILURE");
     line="";
    end else line={line,ch};
   end
  end
 end
endmodule
