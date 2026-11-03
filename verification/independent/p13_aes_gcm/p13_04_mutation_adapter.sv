`timescale 1ns/1ps
// Observation-only self-test: this file is NEVER compiled in functional library.
// This isolated top has no Production DUT, clocks, resets or hierarchical writes.
module p13_04_mutation_adapter(
  input integer fault,
  input wire [31:0] status_in,alias_in,
  input wire [127:0] ciphertext_in,
  output wire [31:0] status_out,alias_out,
  output wire [127:0] ciphertext_out
);
  assign status_out=fault==1 ? status_in ^ 32'h4 : status_in;
  assign ciphertext_out=fault==2 ? {ciphertext_in[119:112],ciphertext_in[127:120],ciphertext_in[111:0]} : ciphertext_in;
  assign alias_out=fault==3 ? 32'd1 : alias_in;
endmodule

module tb_p13_04_sensitivity;
  integer fault=0;
  reg completed=0;
  wire [31:0] s,a;
  wire [127:0] c;
  localparam [127:0] CT=128'h0388dace60b6a392f328c2b971b2fe78;
  p13_04_mutation_adapter adapter(fault,32'h9a,32'b0,CT,s,a,c);
  p13_04_contract_scoreboard score(1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,32'b0,32'b0);
  initial begin
    if (!$value$plusargs("fault=%d",fault)) fault=0;
    #1;
    if (fault!=0) begin
      $display("MUTATION_REACH fault=%0d status_in=0000009a status_out=%08h ct_in=%032h ct_out=%032h alias_in=00000000 alias_out=%08h",fault,s,CT,c,a);
      score.require_true("INJECTION_REACHED",(fault==1 && s===32'h9e) ||
        (fault==2 && c!==CT && c[127:112]===16'h8803) || (fault==3 && a===1));
    end
    score.check32("AUTH_FAIL_STATUS",s,32'h9a);
    score.check128("ORACLE_CIPHERTEXT",c,CT,{128{1'b1}});
    score.check32("ALIAS_RAZ_WI",a,0);
    completed=1; $display("SENSITIVITY_CONTROL_PASS"); $finish;
  end
endmodule
