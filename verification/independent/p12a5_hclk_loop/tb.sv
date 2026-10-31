`timescale 1ns/1ps
module tb;
  reg clk=0;
  always #10 clk=~clk;
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
  integer fd, cycle=0, reset_cycles=0, i;
  reg active=0, loss_pending=0, loss_done=0;
  initial begin
    fd=$fopen("trace.txt","w");
    if(!fd) $fatal(1,"TRACE_OPEN");
    repeat(5) @(negedge clk);
    KEY[0]=1;
  end
  always @(negedge clk) if(loss_pending && !loss_done) begin
    // Explicit OPEN_SIM PLL model stimulus; no production state override.
    dut.U_VRAM.U_PLL.inject_lock_loss();
    loss_done=1; loss_pending=0;
    $fdisplay(fd,"L %0d",cycle);
  end
  always @(posedge clk) begin
    if(!dut.PRESETN_SYS) begin
      reset_cycles=reset_cycles+1;
      // First edge establishes reset state through NBA; observe settled reset afterward.
      if(reset_cycles>1 && dut.u_memory.u_bram.wren!==0) $fatal(1,"RESET_BRAM_WRITE");
    end else begin
      active=1;cycle=cycle+1;
      $fdisplay(fd,"B %0d %h %b %h %h %h %h %b %h %h",cycle,dut.HADDR,dut.HWRITE,dut.HTRANS,dut.HSIZE,dut.HWDATA,dut.CUSTOM_WRITE_MASK_OUT,dut.HREADY,dut.HRESP,dut.HRDATA);
      $fdisplay(fd,"W %0d %b %h %h %h",cycle,dut.u_memory.u_bram.wren,dut.u_memory.u_bram.wraddress,dut.u_memory.u_bram.data,dut.u_memory.u_bram.byteena_a);
      if(dut.u_CPU.commit_valid) $fdisplay(fd,"R %0d %h %h %b %h %h",cycle,dut.u_CPU.WB_pc,dut.u_CPU.WB_instruction,dut.u_CPU.gpr_commit,dut.u_CPU.WB_rd,dut.u_CPU.register_file_write_data);
      if(dut.u_CPU.trap_wr_valid) $fdisplay(fd,"T %0d %h %h",cycle,dut.u_CPU.trap_wr_addr,dut.u_CPU.trap_wr_data);
      if(dut.u_CPU.normal_csr_write) $fdisplay(fd,"C %0d %h %h",cycle,dut.u_CPU.WB_raw_imm[11:0],dut.u_CPU.WB_alu_result);
      if(dut.u_CPU.mem_fault_now) $fdisplay(fd,"F %0d",cycle);
      if(dut.PSEL!=0 && dut.PENABLE) $fdisplay(fd,"P %0d %h %b %h %b %b",cycle,dut.PADDR,dut.PWRITE,dut.PWDATA,dut.APB_SLAVE_PREADY,dut.ADC_SLVERR);
      $fdisplay(fd,"V %0d %b %b %h %h %b %b %b %b",cycle,dut.U_VRAM.u_VRAM0.wren,dut.U_VRAM.u_VRAM1.wren,dut.U_VRAM.u_VRAM1.wraddress,dut.U_VRAM.u_VRAM1.data,dut.U_VRAM.vga_pll_locked,dut.U_VRAM.h_epoch_valid,dut.U_VRAM.domain_ready,dut.U_VRAM.front_bank_h);
      if(dut.u_uart1_pc.tx_accept) $fdisplay(fd,"U %0d %h %h",cycle,dut.PWDATA,dut.u_uart1_pc.programmed_baud_div);
      if(dut.HREADY && dut.HRESP==0 && dut.HTRANS[1] && dut.HADDR==32'h20000004 && !loss_done) loss_pending=1;
      if(cycle==22000) begin
        for(i=0;i<32;i=i+1) $fdisplay(fd,"D %0d %h",i,dut.u_memory.u_bram.words[i]);
        $fdisplay(fd,"S %0d %h %h %h %h %b %b",reset_cycles,dut.u_adc_controller.joy_center_x,dut.u_adc_controller.enable_reg,dut.u_uart1_pc.programmed_baud_div,dut.u_CPU.csr_file.mcause,dut.U_VRAM.operation_busy,dut.U_VRAM.operation_done_sticky);
        $fclose(fd);$display("TARGET_COMPLETE cycles=%0d reset_cycles=%0d",cycle,reset_cycles);$finish;
      end
    end
    if(reset_cycles>1000020 && !active) $fatal(1,"RESET_TIMEOUT");
  end
endmodule
