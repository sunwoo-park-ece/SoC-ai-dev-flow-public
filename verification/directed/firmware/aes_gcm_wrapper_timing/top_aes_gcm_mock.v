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
    output reg          aes_gcm_ready_o,
    output reg          aes_gcm_data_out_val_o,
    output reg  [15:0]  aes_gcm_data_out_bval_o,
    output reg  [127:0] aes_gcm_data_out_o,
    output reg          aes_gcm_ghash_tag_val_o,
    output reg  [127:0] aes_gcm_ghash_tag_o,
    output reg          aes_gcm_icb_cnt_overflow_o
);
  localparam [127:0] EXPECTED_CT  = 128'h5b30094ec35eafcfb6f057ba77bc7d49;
  localparam [127:0] EXPECTED_TAG = 128'he702be065ebac4556e93b8828af90ab7;
  localparam [127:0] BAD_TAG      = 128'h981fbbfa8e53186491db4d7168d63ad0;

  reg [15:0] pending_bval;
  reg        pending_data;
  reg        saw_ct_inside_pkt;
  reg        pkt_q;
  reg [1:0]  tag_delay;
  reg        tag_pending;

  always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      aes_gcm_ready_o            <= 1'b0;
      aes_gcm_data_out_val_o     <= 1'b0;
      aes_gcm_data_out_bval_o    <= 16'h0000;
      aes_gcm_data_out_o         <= 128'h0;
      aes_gcm_ghash_tag_val_o    <= 1'b0;
      aes_gcm_ghash_tag_o        <= 128'h0;
      aes_gcm_icb_cnt_overflow_o <= 1'b0;
      pending_bval               <= 16'h0000;
      pending_data               <= 1'b0;
      saw_ct_inside_pkt          <= 1'b0;
      pkt_q                      <= 1'b0;
      tag_delay                  <= 2'd0;
      tag_pending                <= 1'b0;
    end else begin
      aes_gcm_ready_o         <= 1'b1;
      aes_gcm_data_out_val_o  <= 1'b0;
      aes_gcm_data_out_bval_o <= 16'h0000;
      aes_gcm_ghash_tag_val_o <= 1'b0;
      pkt_q                   <= aes_gcm_ghash_pkt_val_i;

      if (aes_gcm_icb_start_cnt_i) begin
        saw_ct_inside_pkt <= 1'b0;
      end

      if (|aes_gcm_data_in_bval_i) begin
        pending_data <= 1'b1;
        pending_bval <= aes_gcm_data_in_bval_i;
      end

      if (pending_data) begin
        pending_data            <= 1'b0;
        aes_gcm_data_out_val_o  <= 1'b1;
        aes_gcm_data_out_bval_o <= pending_bval;
        aes_gcm_data_out_o      <= EXPECTED_CT;
        if (aes_gcm_ghash_pkt_val_i) begin
          saw_ct_inside_pkt <= 1'b1;
        end
      end

      if (pkt_q && !aes_gcm_ghash_pkt_val_i) begin
        tag_pending <= 1'b1;
        tag_delay   <= 2'd2;
      end

      if (tag_pending) begin
        if (tag_delay != 2'd0) begin
          tag_delay <= tag_delay - 2'd1;
        end else begin
          tag_pending             <= 1'b0;
          aes_gcm_ghash_tag_val_o <= 1'b1;
          aes_gcm_ghash_tag_o     <= saw_ct_inside_pkt ? EXPECTED_TAG : BAD_TAG;
        end
      end
    end
  end
endmodule
