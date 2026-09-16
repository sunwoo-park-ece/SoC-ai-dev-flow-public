// OPEN_SIM Verilator/Icarus structural-only boundary for a VHDL AES-GCM core.
// This module does not implement encryption or authenticate any data.
// GHDL/ModelSim lanes compile the real public VHDL instead.
module top_aes_gcm (
    input  wire         rst_i,
    input  wire         clk_i,
    input  wire [1:0]   aes_gcm_mode_i,
    input  wire         aes_gcm_enc_dec_i,
    input  wire         aes_gcm_pipe_reset_i,
    input  wire [3:0]   aes_gcm_key_word_val_i,
    input  wire [255:0] aes_gcm_key_word_i,
    input  wire         aes_gcm_iv_val_i,
    input  wire [95:0]  aes_gcm_iv_i,
    input  wire         aes_gcm_icb_start_cnt_i,
    input  wire         aes_gcm_icb_stop_cnt_i,
    input  wire         aes_gcm_ghash_pkt_val_i,
    input  wire [15:0]  aes_gcm_ghash_aad_bval_i,
    input  wire [127:0] aes_gcm_ghash_aad_i,
    input  wire [15:0]  aes_gcm_data_in_bval_i,
    input  wire [127:0] aes_gcm_data_in_i,
    output wire         aes_gcm_ready_o,
    output wire         aes_gcm_data_out_val_o,
    output wire [15:0]  aes_gcm_data_out_bval_o,
    output wire [127:0] aes_gcm_data_out_o,
    output wire         aes_gcm_ghash_tag_val_o,
    output wire [127:0] aes_gcm_ghash_tag_o,
    output wire         aes_gcm_icb_cnt_overflow_o
);
    assign aes_gcm_ready_o = 1'b0;
    assign aes_gcm_data_out_val_o = 1'b0;
    assign aes_gcm_data_out_bval_o = 16'd0;
    assign aes_gcm_data_out_o = 128'd0;
    assign aes_gcm_ghash_tag_val_o = 1'b0;
    assign aes_gcm_ghash_tag_o = 128'd0;
    assign aes_gcm_icb_cnt_overflow_o = 1'b0;
endmodule
