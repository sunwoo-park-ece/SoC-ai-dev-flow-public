// Production peripherals; stimulus enters accepted APB/publication/serial ports.
module soc_health_provider_top(
 input logic clk, reset_n,
 input logic [31:0] address, wdata,
 input logic select, enable, write,
 output logic [31:0] rdata, output logic ready, error,
 input logic [31:0] haddr, hwdata,
 input logic hsel, hwrite, input logic [1:0] htrans,
 output logic [31:0] hrdata, output logic hready,
 output logic [1:0] hresp,
 input logic adc_frame_pulse, input logic [31:0] adc_seq,
 input logic [5:0] adc_valid, input logic [71:0] adc_samples,
 input logic [3:0] adc_error,
 input logic gs_irq, input logic gs_miso,
 output logic gs_cs_n, gs_sclk, gs_mosi,
 output logic uart0_tx,
 output logic [31:0] swap_commits, framebuffer_commits
);
 wire [31:0] tdata,u0data,u1data,gdata,adata;
 wire tr,u0r,u1r,gr,ar,ge,ae,adc_req;
 wire [11:0] cx,cy,dz,hx,hy;wire [5:0] hv,joy;
 wire tsel=select&&address[31:16]==16'h4002;
 wire u0sel=select&&address[31:16]==16'h4000;
 wire u1sel=select&&address[31:16]==16'h4006;
 wire gsel=select&&address[31:16]==16'h4003;
 wire asel=select&&address[31:16]==16'h4005;
 APB_TIMER timer(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(tsel),.PENABLE(enable),.PRDATA(tdata),.PREADY(tr));
 APB_UART_LORA uart0(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(u0sel),.PENABLE(enable),.PRDATA(u0data),.PREADY(u0r),.uart_tx(uart0_tx),.uart_rx(1'b1),.lora_aux(1'b0));
 APB_UART uart1(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(u1sel),.PENABLE(enable),.PRDATA(u1data),.PREADY(u1r),.uart_tx(),.uart_rx(uart0_tx));
 APB_GSENSOR_MB gsensor(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(gsel),.PENABLE(enable),.PRDATA(gdata),.PREADY(gr),.PSLVERR(ge),.GSENSOR_CS_N(gs_cs_n),.GSENSOR_SCLK(gs_sclk),.GSENSOR_SDI(gs_mosi),.GSENSOR_SDO(gs_miso),.GSENSOR_INT({1'b0,gs_irq}),.debug_acc_x(),.debug_acc_y());
 APB_ADC_Controller adc(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(asel),.PENABLE(enable),.PRDATA(adata),.PREADY(ar),.PSLVERR(ae),.adc_enable_req(adc_req),.engine_enabled_pclk(adc_req),.frame_pulse_pclk(adc_frame_pulse),.frame_seq_pclk(adc_seq),.valid_mask_pclk(adc_valid),.samples_flat_pclk(adc_samples),.mailbox_busy(1'b0),.error_pulse_pclk(adc_error),.joy_status_i(joy),.joy_center_x_o(cx),.joy_center_y_o(cy),.joy_deadzone_o(dz),.hold_ch1_o(hx),.hold_ch2_o(hy),.hold_valid_mask_o(hv));
 Joystick_Policy policy(.hold_ch1(hx),.hold_ch2(hy),.hold_valid_mask(hv),.center_x(cx),.center_y(cy),.deadzone(dz),.joy_status(joy));
 wire [3:0] vr,vg,vb;wire hs,vs;
 AHB_VRAM_DUAL_BUFFER vga(.CLOCK_50(clk),.HCLK(clk),.HRESETn(reset_n),.HADDR(haddr),.HWRITE(hwrite),.HTRANS(htrans),.HSIZE(3'b010),.HWDATA(hwdata),.HSEL(hsel),.HREADY_IN(hready),.HRDATA(hrdata),.HREADY(hready),.HRESP(hresp),.VGA_R(vr),.VGA_G(vg),.VGA_B(vb),.VGA_HS(hs),.VGA_VS(vs));
 always_comb begin
  rdata=0;ready=1;error=0;
  if(tsel)begin rdata=tdata;ready=tr;end
  else if(u0sel)begin rdata=u0data;ready=u0r;end
  else if(u1sel)begin rdata=u1data;ready=u1r;end
  else if(gsel)begin rdata=gdata;ready=gr;error=ge;end
  else if(asel)begin rdata=adata;ready=ar;error=ae;end
 end
 // Observation only; expected ownership is derived in the driver-side checker.
 always @(posedge clk) begin
  if(!reset_n)begin swap_commits<=0;framebuffer_commits<=0;end
  else begin
   if(vga.accepted_control_write&&hwdata[0])swap_commits<=swap_commits+1;
   if(vga.vram0_we||vga.vram1_we)framebuffer_commits<=framebuffer_commits+1;
   if(vga.vram0_we&&vga.vram1_we)$fatal(1,"BOTH_BANKS");
   if((vga.vram0_we&&vga.front_bank_p==0)||(vga.vram1_we&&vga.front_bank_p==1))$fatal(1,"FRONT_BANK_WRITE");
  end
 end
endmodule
