`timescale 1ns/1ps
// Expected state uses external KEY history and contract addresses only.
module p12a3_soc_vga_ref(input clk, input key_n, output reg released=0);
 reg q1=0,q2=0; integer qualified=0;
 always @(posedge clk or negedge key_n) begin
  if (!key_n) begin q1<=0; q2<=0; qualified<=0; released<=0; end
  else begin
   q1<=1; q2<=q1;
   if (!q2) begin qualified<=0; released<=0; end
   else if (!released) begin
    if (qualified==999999) released<=1;
    else qualified<=qualified+1;
   end
  end
 end
 function automatic integer route(input [31:0] a);
  if (a>=32'h20000000 && a<32'h20020000) route=2;
  else if (a>=32'h10000000 && a<32'h10008000) route=1;
  else route=0;
 endfunction
 function automatic bit framebuffer(input [31:0] a);
  framebuffer=a>=32'h20000000 && a<32'h20009600 && a[1:0]==0;
 endfunction
endmodule
