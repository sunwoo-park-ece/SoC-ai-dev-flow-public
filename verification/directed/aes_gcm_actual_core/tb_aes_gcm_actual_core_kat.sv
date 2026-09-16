`timescale 1ns/1ps

// AES-001: production APB wrapper + real VHDL core. Expected results come
// from Python cryptography 46.0.7 AESGCM, not from this RTL.
module tb_aes_gcm_actual_core_kat;
  reg PCLK = 0;
  reg PRESETn = 0;
  reg [31:0] PADDR = 0, PWDATA = 0;
  reg PWRITE = 0, PSEL = 0, PENABLE = 0;
  wire [31:0] PRDATA;
  wire PREADY;
  reg [31:0] status_word;
  reg [127:0] got_payload, got_tag;
  reg [127:0] payload, expected_payload, expected_tag;
  reg [127:0] valid_mask;
  integer i, polls, done_count, done_rises = 0, failures = 0;
  reg prior_done = 0;
  reg [15:0] length;
  reg decrypt;

  always #5 PCLK = ~PCLK;
  apb_aes_gcm dut (.*);
  always @(posedge PCLK) begin
    if (PRESETn && dut.done_reg && !prior_done) done_rises = done_rises + 1;
    prior_done = dut.done_reg;
  end

  task apb_write(input [31:0] addr, input [31:0] data);
    begin
      @(negedge PCLK);
      PADDR = addr; PWDATA = data; PWRITE = 1; PSEL = 1; PENABLE = 0;
      @(negedge PCLK);
      PENABLE = 1;
      @(negedge PCLK);
      PSEL = 0; PENABLE = 0; PWRITE = 0; PADDR = 0; PWDATA = 0;
    end
  endtask

  task apb_read(input [31:0] addr, output [31:0] data);
    begin
      @(negedge PCLK);
      PADDR = addr; PWRITE = 0; PSEL = 1; PENABLE = 0;
      @(negedge PCLK);
      PENABLE = 1;
      #1 data = PRDATA;
      @(negedge PCLK);
      PSEL = 0; PENABLE = 0; PADDR = 0;
    end
  endtask

  task run_case(input [8*4-1:0] id, input reg is_decrypt,
                input [15:0] nbytes, input [127:0] input_payload,
                input [127:0] want_payload, input [127:0] want_tag);
    begin
      decrypt = is_decrypt; length = nbytes;
      payload = input_payload; expected_payload = want_payload;
      expected_tag = want_tag;
      apb_write('h0c, 4);
      done_rises = 0;
      for (i = 0; i < 4; i = i + 1)
        apb_write('h20 + i*4, 32'h00010203 + 32'h04040404*i);
      apb_write('h30, 32'h10203000);
      apb_write('h34, 0);
      apb_write('h38, 1);
      apb_write('h3c, {16'b0, nbytes});
      for (i = 0; i < 4; i = i + 1) begin
        apb_write('h40 + i*4, input_payload[127-i*32 -: 32]);
        apb_write('h50 + i*4, want_tag[127-i*32 -: 32]);
      end
      apb_write('h0c, is_decrypt ? 3 : 1);
      polls = 0; done_count = 0; status_word = 0;
      while ((status_word & 2) == 0 && polls < 3000) begin
        apb_read('h10, status_word);
        if (status_word & 2) done_count = done_count + 1;
        polls = polls + 1;
      end
      got_payload = 0; got_tag = 0;
      for (i = 0; i < 4; i = i + 1) begin
        apb_read('h60 + i*4, got_payload[127-i*32 -: 32]);
        apb_read('h70 + i*4, got_tag[127-i*32 -: 32]);
      end
      $display("KAT %0s op=%0s len=%0d status=%08x polls=%0d completions=%0d", id,
               is_decrypt ? "D" : "E", nbytes, status_word, polls, done_count);
      $display("  payload expected=%032x observed=%032x", want_payload, got_payload);
      $display("  tag     expected=%032x observed=%032x", want_tag, got_tag);
      valid_mask = nbytes == 0 ? 128'h0 :
                   (128'hffffffffffffffffffffffffffffffff << ((16-nbytes)*8));
      if ((status_word & 'hf) !== 'h6 ||
          (got_payload & valid_mask) !== (want_payload & valid_mask) ||
          got_tag !== want_tag || done_count != 1) begin
        $display("KAT %0s FAIL", id);
        failures = failures + 1;
      end else $display("KAT %0s PASS", id);
      repeat (5) @(negedge PCLK);
      if (done_rises != 1) begin
        $display("KAT %0s FAIL done_rises=%0d", id, done_rises);
        failures = failures + 1;
      end
      if (failures != 0) begin
        $display("SUMMARY: FAIL first=%0s", id);
        $finish;
      end
    end
  endtask

  initial begin
    repeat (5) @(negedge PCLK);
    PRESETn = 1;
    repeat (3) @(negedge PCLK);
    run_case("E0", 0, 0, 128'h0, 128'h0,
             128'h62344254fcd95e1ec42b27bf38efba1c);
    run_case("D0", 1, 0, 128'h0, 128'h0,
             128'h62344254fcd95e1ec42b27bf38efba1c);
    run_case("EP", 0, 7, 128'h10111213141516000000000000000000,
             128'h5b201b5dd74bb9000000000000000000,
             128'he39af015075d18019e78e344b285d1ec);
    run_case("DP", 1, 7, 128'h5b201b5dd74bb9000000000000000000,
             128'h10111213141516000000000000000000,
             128'he39af015075d18019e78e344b285d1ec);
    run_case("E16", 0, 16, 128'h101112131415161718191a1b1c1d1e1f,
             128'h5b201b5dd74bb9d8aee94da16ba16356,
             128'h9ee8eb4a087279dac5f75d8e930d5f69);
    run_case("D16", 1, 16, 128'h5b201b5dd74bb9d8aee94da16ba16356,
             128'h101112131415161718191a1b1c1d1e1f,
             128'h9ee8eb4a087279dac5f75d8e930d5f69);
    $display("SUMMARY: PASS six actual-core AES-128-GCM KATs");
    $finish;
  end
endmodule
