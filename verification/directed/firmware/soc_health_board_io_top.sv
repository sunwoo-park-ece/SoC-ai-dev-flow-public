// Simulated external GPIO0 -> GPIO1 jumper. This is not physical board evidence.
module soc_health_board_io_top(
 input logic clk,reset_n,select,enable,write,
 input logic [31:0] address,wdata,
 output logic [31:0] rdata,output logic ready,
 input logic [9:0] switches,input logic [1:0] loop_fault,
 output wire [9:0] leds,output wire [41:0] segments,
 output wire drive_pin,sense_pin
);
 wire [31:0] gd,sd,ld,hd;wire gr,sr,lr,hr;
 wire gs=select&&address[31:16]==16'h4001;
 wire ss=select&&address[31:16]==16'h4008;
 wire ls=select&&address[31:16]==16'h4009;
 wire hs=select&&address[31:16]==16'h4007;
 tri [15:0] pins;
 assign pins[15:2]=14'b0;
 assign pins[1]=loop_fault==0?pins[0]:loop_fault==1?1'b0:loop_fault==2?1'b1:~pins[0];
 assign drive_pin=pins[0];assign sense_pin=pins[1];
 APB_GPIO gpio(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(gs),.PENABLE(enable),.PRDATA(gd),.PREADY(gr),.GPIO_IO(pins),.gpio_irq());
 APB_SW sw(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(ss),.PENABLE(enable),.PRDATA(sd),.PREADY(sr),.SW(switches));
 APB_LED led(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(ls),.PENABLE(enable),.PRDATA(ld),.PREADY(lr),.LEDR(leds));
 APB_HEX_display hex(.PCLK(clk),.PRESETn(reset_n),.PADDR(address),.PWDATA(wdata),.PWRITE(write),.PSEL(hs),.PENABLE(enable),.PRDATA(hd),.PREADY(hr),.HEX0(segments[6:0]),.HEX1(segments[13:7]),.HEX2(segments[20:14]),.HEX3(segments[27:21]),.HEX4(segments[34:28]),.HEX5(segments[41:35]));
 always_comb begin
  rdata=0;ready=1;
  if(gs)begin rdata=gd;ready=gr;end
  else if(ss)begin rdata=sd;ready=sr;end
  else if(ls)begin rdata=ld;ready=lr;end
  else if(hs)begin rdata=hd;ready=hr;end
 end
endmodule
