// --------------------------------------------------------------------------
// APB AES-GCM Wrapper (IP instance version)
// - Target pipe directory: pipe_0
// - Purpose: Quartus STA / synthesis integration wrapper
// --------------------------------------------------------------------------
module apb_aes_gcm #(
    parameter integer PIPE_CFG = 0
) (
    input  wire        PCLK,
    input  wire        PRESETn,
    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY
);
  assign PREADY = 1'b1;

  // --------------------------------------------------------------------------
  // Address map (word aligned, decoded with PADDR[7:2])
  // --------------------------------------------------------------------------
  localparam [5:0] ADDR_NAME0        = 6'h00; // 0x00
  localparam [5:0] ADDR_NAME1        = 6'h01; // 0x04
  localparam [5:0] ADDR_VERSION      = 6'h02; // 0x08
  localparam [5:0] ADDR_CTRL         = 6'h03; // 0x0C
  localparam [5:0] ADDR_STATUS       = 6'h04; // 0x10

  localparam [5:0] ADDR_KEY0         = 6'h08; // 0x20
  localparam [5:0] ADDR_KEY1         = 6'h09; // 0x24
  localparam [5:0] ADDR_KEY2         = 6'h0A; // 0x28
  localparam [5:0] ADDR_KEY3         = 6'h0B; // 0x2C

  localparam [5:0] ADDR_NONCE_DIR    = 6'h0C; // 0x30 [31:8]=session_nonce(24), [7:0]=DIR
  localparam [5:0] ADDR_SEQ_HI       = 6'h0D; // 0x34
  localparam [5:0] ADDR_SEQ_LO       = 6'h0E; // 0x38
  localparam [5:0] ADDR_LEN          = 6'h0F; // 0x3C [15:0]

  localparam [5:0] ADDR_PAYLOAD_IN0  = 6'h10; // 0x40
  localparam [5:0] ADDR_PAYLOAD_IN1  = 6'h11; // 0x44
  localparam [5:0] ADDR_PAYLOAD_IN2  = 6'h12; // 0x48
  localparam [5:0] ADDR_PAYLOAD_IN3  = 6'h13; // 0x4C

  localparam [5:0] ADDR_TAG_IN0      = 6'h14; // 0x50
  localparam [5:0] ADDR_TAG_IN1      = 6'h15; // 0x54
  localparam [5:0] ADDR_TAG_IN2      = 6'h16; // 0x58
  localparam [5:0] ADDR_TAG_IN3      = 6'h17; // 0x5C

  localparam [5:0] ADDR_PAYLOAD_OUT0 = 6'h18; // 0x60
  localparam [5:0] ADDR_PAYLOAD_OUT1 = 6'h19; // 0x64
  localparam [5:0] ADDR_PAYLOAD_OUT2 = 6'h1A; // 0x68
  localparam [5:0] ADDR_PAYLOAD_OUT3 = 6'h1B; // 0x6C

  localparam [5:0] ADDR_TAG_OUT0     = 6'h1C; // 0x70
  localparam [5:0] ADDR_TAG_OUT1     = 6'h1D; // 0x74
  localparam [5:0] ADDR_TAG_OUT2     = 6'h1E; // 0x78
  localparam [5:0] ADDR_TAG_OUT3     = 6'h1F; // 0x7C

  localparam [5:0] ADDR_HDR0         = 6'h20; // 0x80 debug: MAGIC|IV|LEN
  localparam [5:0] ADDR_HDR1         = 6'h21; // 0x84
  localparam [5:0] ADDR_HDR2         = 6'h22; // 0x88
  localparam [5:0] ADDR_HDR3         = 6'h23; // 0x8C

  // CTRL bits
  localparam CTRL_START_BIT       = 0;
  localparam CTRL_ENCDEC_BIT      = 1; // 0: encrypt, 1: decrypt
  localparam CTRL_CLR_STATUS_BIT  = 2; // write 1 to clear done/tag_ok/error

  // STATUS bits
  localparam STATUS_BUSY_BIT      = 0;
  localparam STATUS_DONE_BIT      = 1;
  localparam STATUS_TAG_OK_BIT    = 2;
  localparam STATUS_ERROR_BIT     = 3;

  // Core constants
  localparam [15:0] MAGIC_CONST   = 16'hA55A;
  localparam [31:0] CORE_NAME0    = 32'h6170622d; // "apb-"
  localparam [31:0] CORE_NAME1    = 32'h67636d20; // "gcm "
  localparam [31:0] CORE_VERSION  = 32'h312e3030; // "1.00"

  // --------------------------------------------------------------------------
  // APB regs
  // --------------------------------------------------------------------------
  reg        enc_dec_reg;
  reg        busy_reg;
  reg        done_reg;
  reg        tag_ok_reg;
  reg        error_reg;

  reg [31:0] key_reg [0:3];
  reg [31:0] payload_in_reg [0:3];
  reg [31:0] payload_out_reg [0:3];
  reg [31:0] tag_in_reg [0:3];
  reg [31:0] tag_out_reg [0:3];
  reg [31:0] hdr_dbg_reg [0:3];

  reg [31:0] nonce_dir_reg;
  reg [31:0] seq_hi_reg;
  reg [31:0] seq_lo_reg;
  reg [31:0] len_reg;

  // --------------------------------------------------------------------------
  // Core control/data regs
  // --------------------------------------------------------------------------
  reg  [1:0]   core_mode_reg;
  reg          core_enc_dec_reg;
  reg          core_pipe_reset_reg;
  reg  [3:0]   core_key_word_val_reg;
  reg  [255:0] core_key_word_reg;
  reg          core_iv_val_reg;
  reg  [95:0]  core_iv_reg;
  reg          core_icb_start_reg;
  reg          core_icb_stop_reg;
  reg          core_ghash_pkt_val_reg;
  reg  [15:0]  core_ghash_aad_bval_reg;
  reg  [127:0] core_ghash_aad_reg;
  reg  [15:0]  core_data_in_bval_reg;
  reg  [127:0] core_data_in_reg;
  reg          core_soft_reset_reg;

  wire         core_ready;
  wire         core_data_out_val;
  wire [15:0]  core_data_out_bval;
  wire [127:0] core_data_out;
  wire         core_tag_val;
  wire [127:0] core_tag_out;
  wire         core_icb_overflow;

  // --------------------------------------------------------------------------
  // Local wires
  // --------------------------------------------------------------------------
  wire [5:0] addr_word = PADDR[7:2];
  wire       apb_write = (PSEL && PENABLE && PWRITE);
  wire       apb_read  = (PSEL && PENABLE && !PWRITE);
  wire       apb_ctrl_write = (apb_write && (addr_word == ADDR_CTRL));
  wire       start_cmd = (apb_ctrl_write && PWDATA[CTRL_START_BIT]);

  wire [95:0] iv_wire = {nonce_dir_reg[31:8], nonce_dir_reg[7:0], seq_hi_reg, seq_lo_reg};
  wire [127:0] hdr_wire = {MAGIC_CONST, nonce_dir_reg, seq_hi_reg, seq_lo_reg, len_reg[15:0]};
  wire [127:0] payload_in_wire = {payload_in_reg[0], payload_in_reg[1], payload_in_reg[2], payload_in_reg[3]};
  wire [127:0] tag_in_wire = {tag_in_reg[0], tag_in_reg[1], tag_in_reg[2], tag_in_reg[3]};
  wire [255:0] key256_wire = {key_reg[0], key_reg[1], key_reg[2], key_reg[3], 128'h0};

  function [15:0] bval_from_len;
    input [15:0] len;
    begin
      case (len)
        16'd0:  bval_from_len = 16'h0000;
        16'd1:  bval_from_len = 16'h8000;
        16'd2:  bval_from_len = 16'hC000;
        16'd3:  bval_from_len = 16'hE000;
        16'd4:  bval_from_len = 16'hF000;
        16'd5:  bval_from_len = 16'hF800;
        16'd6:  bval_from_len = 16'hFC00;
        16'd7:  bval_from_len = 16'hFE00;
        16'd8:  bval_from_len = 16'hFF00;
        16'd9:  bval_from_len = 16'hFF80;
        16'd10: bval_from_len = 16'hFFC0;
        16'd11: bval_from_len = 16'hFFE0;
        16'd12: bval_from_len = 16'hFFF0;
        16'd13: bval_from_len = 16'hFFF8;
        16'd14: bval_from_len = 16'hFFFC;
        16'd15: bval_from_len = 16'hFFFE;
        default:bval_from_len = 16'hFFFF;
      endcase
    end
  endfunction

  // --------------------------------------------------------------------------
  // Small control FSM
  // --------------------------------------------------------------------------
  localparam [3:0] ST_IDLE        = 4'd0;
  localparam [3:0] ST_CORE_RESET  = 4'd1;
  localparam [3:0] ST_KEY_PULSE   = 4'd2;
  localparam [3:0] ST_WAIT_READY  = 4'd3;
  localparam [3:0] ST_SEND_AAD    = 4'd4;
  localparam [3:0] ST_SEND_DATA   = 4'd5;
  localparam [3:0] ST_PKT_END     = 4'd6;
  localparam [3:0] ST_WAIT_RESULT = 4'd7;
  localparam [3:0] ST_DONE_PULSE  = 4'd8;
  localparam [3:0] ST_WAIT_CT     = 4'd9;
  localparam [3:0] ST_IV_START    = 4'd10;

  reg [3:0] state_reg;
  reg       got_data_reg;
  reg       got_tag_reg;
  reg       tag_match_reg;

  // --------------------------------------------------------------------------
  // VHDL core instance
  // --------------------------------------------------------------------------
  top_aes_gcm u_aes_gcm (
      .rst_i                      (~PRESETn | core_soft_reset_reg),
      .clk_i                      (PCLK),
      .aes_gcm_mode_i             (core_mode_reg),
      .aes_gcm_enc_dec_i          (core_enc_dec_reg),
      .aes_gcm_pipe_reset_i       (core_pipe_reset_reg),
      .aes_gcm_key_word_val_i     (core_key_word_val_reg),
      .aes_gcm_key_word_i         (core_key_word_reg),
      .aes_gcm_iv_val_i           (core_iv_val_reg),
      .aes_gcm_iv_i               (core_iv_reg),
      .aes_gcm_icb_start_cnt_i    (core_icb_start_reg),
      .aes_gcm_icb_stop_cnt_i     (core_icb_stop_reg),
      .aes_gcm_ghash_pkt_val_i    (core_ghash_pkt_val_reg),
      .aes_gcm_ghash_aad_bval_i   (core_ghash_aad_bval_reg),
      .aes_gcm_ghash_aad_i        (core_ghash_aad_reg),
      .aes_gcm_data_in_bval_i     (core_data_in_bval_reg),
      .aes_gcm_data_in_i          (core_data_in_reg),
      .aes_gcm_ready_o            (core_ready),
      .aes_gcm_data_out_val_o     (core_data_out_val),
      .aes_gcm_data_out_bval_o    (core_data_out_bval),
      .aes_gcm_data_out_o         (core_data_out),
      .aes_gcm_ghash_tag_val_o    (core_tag_val),
      .aes_gcm_ghash_tag_o        (core_tag_out),
      .aes_gcm_icb_cnt_overflow_o (core_icb_overflow)
  );

  // --------------------------------------------------------------------------
  // Register write + core drive
  // --------------------------------------------------------------------------
  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      enc_dec_reg <= 1'b0;
      busy_reg    <= 1'b0;
      done_reg    <= 1'b0;
      tag_ok_reg  <= 1'b0;
      error_reg   <= 1'b0;

      key_reg[0] <= 32'h0; key_reg[1] <= 32'h0; key_reg[2] <= 32'h0; key_reg[3] <= 32'h0;
      payload_in_reg[0] <= 32'h0; payload_in_reg[1] <= 32'h0; payload_in_reg[2] <= 32'h0; payload_in_reg[3] <= 32'h0;
      payload_out_reg[0] <= 32'h0; payload_out_reg[1] <= 32'h0; payload_out_reg[2] <= 32'h0; payload_out_reg[3] <= 32'h0;
      tag_in_reg[0] <= 32'h0; tag_in_reg[1] <= 32'h0; tag_in_reg[2] <= 32'h0; tag_in_reg[3] <= 32'h0;
      tag_out_reg[0] <= 32'h0; tag_out_reg[1] <= 32'h0; tag_out_reg[2] <= 32'h0; tag_out_reg[3] <= 32'h0;
      hdr_dbg_reg[0] <= 32'h0; hdr_dbg_reg[1] <= 32'h0; hdr_dbg_reg[2] <= 32'h0; hdr_dbg_reg[3] <= 32'h0;
      nonce_dir_reg <= 32'h0;
      seq_hi_reg    <= 32'h0;
      seq_lo_reg    <= 32'h0;
      len_reg       <= 32'h0;

      core_mode_reg           <= 2'b00;
      core_enc_dec_reg        <= 1'b0;
      core_pipe_reset_reg     <= 1'b0;
      core_key_word_val_reg   <= 4'b0000;
      core_key_word_reg       <= 256'h0;
      core_iv_val_reg         <= 1'b0;
      core_iv_reg             <= 96'h0;
      core_icb_start_reg      <= 1'b0;
      core_icb_stop_reg       <= 1'b0;
      core_ghash_pkt_val_reg  <= 1'b0;
      core_ghash_aad_bval_reg <= 16'h0000;
      core_ghash_aad_reg      <= 128'h0;
      core_data_in_bval_reg   <= 16'h0000;
      core_data_in_reg        <= 128'h0;
      core_soft_reset_reg     <= 1'b0;

      state_reg <= ST_IDLE;
      got_data_reg <= 1'b0;
      got_tag_reg <= 1'b0;
      tag_match_reg <= 1'b0;
    end else begin
      // 기본 one-shot 신호 내림
      core_key_word_val_reg   <= 4'b0000;
      core_iv_val_reg         <= 1'b0;
      core_icb_start_reg      <= 1'b0;
      core_icb_stop_reg       <= 1'b0;
      core_ghash_aad_bval_reg <= 16'h0000;
      core_data_in_bval_reg   <= 16'h0000;
      core_soft_reset_reg     <= 1'b0;

      // APB writes
      if (apb_write) begin
        case (addr_word)
          ADDR_CTRL: begin
            enc_dec_reg <= PWDATA[CTRL_ENCDEC_BIT];
            if (PWDATA[CTRL_CLR_STATUS_BIT]) begin
              done_reg   <= 1'b0;
              tag_ok_reg <= 1'b0;
              error_reg  <= 1'b0;
            end
          end
          ADDR_KEY0: key_reg[0] <= PWDATA;
          ADDR_KEY1: key_reg[1] <= PWDATA;
          ADDR_KEY2: key_reg[2] <= PWDATA;
          ADDR_KEY3: key_reg[3] <= PWDATA;
          ADDR_NONCE_DIR: nonce_dir_reg <= PWDATA;
          ADDR_SEQ_HI:    seq_hi_reg    <= PWDATA;
          ADDR_SEQ_LO:    seq_lo_reg    <= PWDATA;
          ADDR_LEN:       len_reg       <= {16'h0, PWDATA[15:0]};
          ADDR_PAYLOAD_IN0: payload_in_reg[0] <= PWDATA;
          ADDR_PAYLOAD_IN1: payload_in_reg[1] <= PWDATA;
          ADDR_PAYLOAD_IN2: payload_in_reg[2] <= PWDATA;
          ADDR_PAYLOAD_IN3: payload_in_reg[3] <= PWDATA;
          ADDR_TAG_IN0: tag_in_reg[0] <= PWDATA;
          ADDR_TAG_IN1: tag_in_reg[1] <= PWDATA;
          ADDR_TAG_IN2: tag_in_reg[2] <= PWDATA;
          ADDR_TAG_IN3: tag_in_reg[3] <= PWDATA;
          default: ;
        endcase
      end

      // start trigger
      if (start_cmd) begin
        if (busy_reg) begin
          error_reg <= 1'b1;
        end else begin
          busy_reg    <= 1'b1;
          done_reg    <= 1'b0;
          tag_ok_reg  <= 1'b0;
          enc_dec_reg <= PWDATA[CTRL_ENCDEC_BIT];

          // snapshot debug header
          hdr_dbg_reg[0] <= hdr_wire[127:96];
          hdr_dbg_reg[1] <= hdr_wire[95:64];
          hdr_dbg_reg[2] <= hdr_wire[63:32];
          hdr_dbg_reg[3] <= hdr_wire[31:0];

          // core setup
          core_mode_reg       <= 2'b00; // AES-128
          core_enc_dec_reg    <= PWDATA[CTRL_ENCDEC_BIT];
          core_key_word_reg   <= key256_wire;
          core_iv_reg         <= iv_wire;
          core_ghash_aad_reg  <= hdr_wire;
          core_data_in_reg    <= payload_in_wire;
          core_ghash_pkt_val_reg <= 1'b0;

          got_data_reg   <= (len_reg[15:0] == 16'd0);
          got_tag_reg    <= 1'b0;
          tag_match_reg  <= 1'b0;
          if (len_reg[15:0] == 16'd0) begin
            payload_out_reg[0] <= 32'h0;
            payload_out_reg[1] <= 32'h0;
            payload_out_reg[2] <= 32'h0;
            payload_out_reg[3] <= 32'h0;
          end

          state_reg <= ST_CORE_RESET;
        end
      end

      // FSM
      case (state_reg)
        ST_IDLE: begin
        end

        ST_CORE_RESET: begin
          core_soft_reset_reg <= 1'b1;
          state_reg <= ST_KEY_PULSE;
        end

        ST_KEY_PULSE: begin
          if (core_soft_reset_reg) begin
            state_reg <= ST_KEY_PULSE; // wait 1 cycle after releasing core reset
          end else begin
            // The upstream AES-GCM IP requires IV loading after key_val has fallen.
            core_key_word_val_reg <= 4'b0100; // AES-128 key valid
            state_reg <= ST_IV_START;
          end
        end

        ST_IV_START: begin
            core_iv_val_reg       <= 1'b1;
            core_icb_start_reg    <= 1'b1;
            state_reg <= ST_WAIT_READY;
        end

        ST_WAIT_READY: begin
          if (core_ready) begin
            core_ghash_pkt_val_reg  <= 1'b1;
            core_ghash_aad_bval_reg <= 16'hFFFF; // header is always 16B
            state_reg <= ST_SEND_AAD;
          end
        end

        ST_SEND_AAD: begin
          if (len_reg[15:0] != 16'd0) begin
            state_reg <= ST_SEND_DATA;
          end else begin
            state_reg <= ST_PKT_END;
          end
        end

        ST_SEND_DATA: begin
          core_data_in_bval_reg <= bval_from_len(len_reg[15:0]);
          if (core_ready) begin
            state_reg <= ST_WAIT_CT;
          end
        end

        ST_WAIT_CT: begin
          // Keep ghash_pkt_val asserted one extra cycle so the delayed GCTR
          // ciphertext/bval pulse is consumed by GHASH before packet end.
          state_reg <= ST_PKT_END;
        end

        ST_PKT_END: begin
          core_ghash_pkt_val_reg <= 1'b0;
          state_reg <= ST_WAIT_RESULT;
        end

        ST_WAIT_RESULT: begin
          if (core_icb_overflow) begin
            error_reg <= 1'b1;
          end
        end

        ST_DONE_PULSE: begin
          state_reg <= ST_IDLE;
        end

        default: begin
          state_reg <= ST_IDLE;
        end
      endcase

      // Output capture is independent from the drive FSM to avoid missing short valid pulses.
      if (busy_reg) begin
        if (core_data_out_val && !got_data_reg) begin
          payload_out_reg[0] <= core_data_out[127:96];
          payload_out_reg[1] <= core_data_out[95:64];
          payload_out_reg[2] <= core_data_out[63:32];
          payload_out_reg[3] <= core_data_out[31:0];
          got_data_reg <= 1'b1;
        end

        if (core_tag_val && !got_tag_reg) begin
          tag_out_reg[0] <= core_tag_out[127:96];
          tag_out_reg[1] <= core_tag_out[95:64];
          tag_out_reg[2] <= core_tag_out[63:32];
          tag_out_reg[3] <= core_tag_out[31:0];
          got_tag_reg <= 1'b1;
          if (core_enc_dec_reg) begin
            tag_match_reg <= (core_tag_out == tag_in_wire);
          end else begin
            tag_match_reg <= 1'b1;
          end
        end

        if (got_data_reg && got_tag_reg) begin
          busy_reg   <= 1'b0;
          done_reg   <= 1'b1;
          tag_ok_reg <= tag_match_reg;
          if (!tag_match_reg) begin
            error_reg <= 1'b1;
          end
          core_icb_stop_reg <= 1'b1;
          state_reg <= ST_DONE_PULSE;
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // APB reads
  // --------------------------------------------------------------------------
  always @(*) begin
    PRDATA = 32'h0;
    if (apb_read) begin
      case (addr_word)
        ADDR_NAME0:   PRDATA = CORE_NAME0;
        ADDR_NAME1:   PRDATA = CORE_NAME1;
        ADDR_VERSION: PRDATA = CORE_VERSION;
        ADDR_CTRL: PRDATA = {29'h0, 1'b0, enc_dec_reg, 1'b0};
        ADDR_STATUS: PRDATA = {28'h0, error_reg, tag_ok_reg, done_reg, busy_reg};

        ADDR_KEY0: PRDATA = key_reg[0];
        ADDR_KEY1: PRDATA = key_reg[1];
        ADDR_KEY2: PRDATA = key_reg[2];
        ADDR_KEY3: PRDATA = key_reg[3];

        ADDR_NONCE_DIR: PRDATA = nonce_dir_reg;
        ADDR_SEQ_HI:    PRDATA = seq_hi_reg;
        ADDR_SEQ_LO:    PRDATA = seq_lo_reg;
        ADDR_LEN:       PRDATA = len_reg;

        ADDR_PAYLOAD_IN0: PRDATA = payload_in_reg[0];
        ADDR_PAYLOAD_IN1: PRDATA = payload_in_reg[1];
        ADDR_PAYLOAD_IN2: PRDATA = payload_in_reg[2];
        ADDR_PAYLOAD_IN3: PRDATA = payload_in_reg[3];

        ADDR_TAG_IN0: PRDATA = tag_in_reg[0];
        ADDR_TAG_IN1: PRDATA = tag_in_reg[1];
        ADDR_TAG_IN2: PRDATA = tag_in_reg[2];
        ADDR_TAG_IN3: PRDATA = tag_in_reg[3];

        ADDR_PAYLOAD_OUT0: PRDATA = payload_out_reg[0];
        ADDR_PAYLOAD_OUT1: PRDATA = payload_out_reg[1];
        ADDR_PAYLOAD_OUT2: PRDATA = payload_out_reg[2];
        ADDR_PAYLOAD_OUT3: PRDATA = payload_out_reg[3];

        ADDR_TAG_OUT0: PRDATA = tag_out_reg[0];
        ADDR_TAG_OUT1: PRDATA = tag_out_reg[1];
        ADDR_TAG_OUT2: PRDATA = tag_out_reg[2];
        ADDR_TAG_OUT3: PRDATA = tag_out_reg[3];

        ADDR_HDR0: PRDATA = hdr_dbg_reg[0];
        ADDR_HDR1: PRDATA = hdr_dbg_reg[1];
        ADDR_HDR2: PRDATA = hdr_dbg_reg[2];
        ADDR_HDR3: PRDATA = hdr_dbg_reg[3];

        default: PRDATA = 32'h0;
      endcase
    end
  end

endmodule
