`timescale 1ns/1ps
// ISOLATED CONTROL FIXTURE ONLY. Never include in an actual-core/vendor list.
// Implements no AES. Synthetic callbacks establish wrapper control behavior.
module top_aes_gcm(
  input wire rst_i, clk_i,
  input wire [1:0] aes_gcm_mode_i,
  input wire aes_gcm_enc_dec_i, aes_gcm_pipe_reset_i,
  input wire [3:0] aes_gcm_key_word_val_i,
  input wire [255:0] aes_gcm_key_word_i,
  input wire aes_gcm_iv_val_i,
  input wire [95:0] aes_gcm_iv_i,
  input wire aes_gcm_icb_start_cnt_i, aes_gcm_icb_stop_cnt_i,
  input wire aes_gcm_ghash_pkt_val_i,
  input wire [15:0] aes_gcm_ghash_aad_bval_i,
  input wire [127:0] aes_gcm_ghash_aad_i,
  input wire [15:0] aes_gcm_data_in_bval_i,
  input wire [127:0] aes_gcm_data_in_i,
  output wire aes_gcm_ready_o,
  output reg aes_gcm_data_out_val_o=0,
  output reg [15:0] aes_gcm_data_out_bval_o=0,
  output reg [127:0] aes_gcm_data_out_o=0,
  output reg aes_gcm_ghash_tag_val_o=0,
  output reg [127:0] aes_gcm_ghash_tag_o=0,
  output reg aes_gcm_icb_cnt_overflow_o=0
);
  integer reset_edges=0;
  assign aes_gcm_ready_o = !rst_i;
  // Calls are permitted only in this isolated fixture lane, at falling edges.
  task respond(input ov, dv, tv, input [127:0] data_value, tag_value);
    begin
      aes_gcm_icb_cnt_overflow_o=ov;
      aes_gcm_data_out_val_o=dv; aes_gcm_data_out_bval_o=dv ? 16'hffff:0;
      aes_gcm_data_out_o=data_value;
      aes_gcm_ghash_tag_val_o=tv; aes_gcm_ghash_tag_o=tag_value;
      $display("FIXTURE_REACH overflow=%0b data=%0b tag=%0b reset=%0b",ov,dv,tv,rst_i);
    end
  endtask
  always @(posedge clk_i) begin
    if (rst_i) reset_edges <= reset_edges+1;
    aes_gcm_icb_cnt_overflow_o <= 0;
    aes_gcm_data_out_val_o <= 0;
    aes_gcm_ghash_tag_val_o <= 0;
    aes_gcm_data_out_bval_o <= 0;
  end
endmodule

// Monitor-input self-test: never changes DUT, bus stimulus, or core callbacks.
// Each fault targets a particular independent assertion and logs reach.
module p13_observation_fault_adapter(
 input wire clk, psel, penable, pwrite,
 input wire [31:0] raw_data,
 input integer fault_site,
 output reg [31:0] observed
);
 integer fault=0;
 initial if (!$value$plusargs("fault=%d",fault)) fault=0;
 always @* begin
   observed=raw_data;
   if (fault!=0 && fault_site==fault)
     case(fault)
       1: observed=raw_data ^ 32'h1;
       2: observed=raw_data ^ 32'h1;
       3: observed=raw_data | 32'h4;
       4: observed=raw_data ^ 32'h1;
     endcase
 end
 always @(posedge clk)
   if (psel && penable && !pwrite && fault!=0 && fault_site==fault)
     $display("MUTATION_REACH fault=%0d raw=%08x observed=%08x layer=checker_input",fault,raw_data,observed);
endmodule
