(* blackbox *)
module IMEM #(
    parameter INIT_FILE = ""
) (
    input  wire        aclr,
    input  wire [11:0] address,
    input  wire        clken,
    input  wire        clock,
    output reg  [31:0] q
);
endmodule

(* blackbox *)
module memory #(
    parameter INIT_FILE = ""
) (
    input  wire [3:0]  byteena_a,
    input  wire        clock,
    input  wire [31:0] data,
    input  wire [12:0] rdaddress,
    input  wire        rden,
    input  wire [12:0] wraddress,
    input  wire        wren,
    output reg  [31:0] q
);
endmodule

(* blackbox *)
module VRAM (
    input  wire [31:0] data,
    input  wire        rd_aclr,
    input  wire [18:0] rdaddress,
    input  wire        rdclock,
    input  wire [13:0] wraddress,
    input  wire        wrclock,
    input  wire        wren,
    output reg         q
);
endmodule

(* blackbox *)
module vga_pll (
    input  wire inclk0,
    output reg  c0,
    output reg  locked
);
endmodule

(* blackbox *)
module spi_pll (
    input  wire areset,
    input  wire inclk0,
    output wire c0,
    output wire c1
);
endmodule

(* blackbox *)
module adc_qsys #(
    parameter integer RESPONSE_LATENCY = 3,
    parameter [11:0] CHANNEL1_SAMPLE = 12'h600,
    parameter [11:0] CHANNEL2_SAMPLE = 12'hA00,
    parameter [11:0] DEFAULT_SAMPLE  = 12'h800
) (
    input  wire        clk_clk,
    output wire        clock_bridge_sys_out_clk_clk,
    input  wire        modular_adc_0_command_valid,
    input  wire [4:0]  modular_adc_0_command_channel,
    input  wire        modular_adc_0_command_startofpacket,
    input  wire        modular_adc_0_command_endofpacket,
    output wire        modular_adc_0_command_ready,
    output reg         modular_adc_0_response_valid,
    output reg  [4:0]  modular_adc_0_response_channel,
    output reg  [11:0] modular_adc_0_response_data,
    output reg         modular_adc_0_response_startofpacket,
    output reg         modular_adc_0_response_endofpacket,
    input  wire        reset_reset_n
);
endmodule

(* blackbox *)
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
endmodule
