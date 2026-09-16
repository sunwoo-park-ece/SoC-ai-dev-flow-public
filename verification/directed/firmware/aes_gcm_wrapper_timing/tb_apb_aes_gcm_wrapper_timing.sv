`timescale 1ns/1ps

module tb_apb_aes_gcm_wrapper_timing;
  localparam [31:0] CTRL         = 32'h0c;
  localparam [31:0] STATUS       = 32'h10;
  localparam [31:0] KEY0         = 32'h20;
  localparam [31:0] NONCE_DIR    = 32'h30;
  localparam [31:0] SEQ_HI       = 32'h34;
  localparam [31:0] SEQ_LO       = 32'h38;
  localparam [31:0] LEN          = 32'h3c;
  localparam [31:0] PAYLOAD_IN0  = 32'h40;
  localparam [31:0] PAYLOAD_OUT0 = 32'h60;
  localparam [31:0] TAG_OUT0     = 32'h70;

  localparam [127:0] EXPECTED_CT  = 128'h5b30094ec35eafcfb6f057ba77bc7d49;
  localparam [127:0] EXPECTED_TAG = 128'he702be065ebac4556e93b8828af90ab7;

  reg         PCLK = 1'b0;
  reg         PRESETn = 1'b0;
  reg  [31:0] PADDR = 32'h0;
  reg         PWRITE = 1'b0;
  reg         PSEL = 1'b0;
  reg         PENABLE = 1'b0;
  reg  [31:0] PWDATA = 32'h0;
  wire [31:0] PRDATA;
  wire        PREADY;

  reg [31:0] rdata;
  reg [127:0] ct;
  reg [127:0] tag;
  integer timeout;

  always #5 PCLK = ~PCLK;

  apb_aes_gcm dut (
      .PCLK(PCLK),
      .PRESETn(PRESETn),
      .PADDR(PADDR),
      .PWRITE(PWRITE),
      .PSEL(PSEL),
      .PENABLE(PENABLE),
      .PWDATA(PWDATA),
      .PRDATA(PRDATA),
      .PREADY(PREADY)
  );

  task apb_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge PCLK);
      PADDR <= addr; PWDATA <= data; PWRITE <= 1'b1; PSEL <= 1'b1; PENABLE <= 1'b0;
      @(posedge PCLK);
      PENABLE <= 1'b1;
      @(posedge PCLK);
      PSEL <= 1'b0; PENABLE <= 1'b0; PWRITE <= 1'b0; PADDR <= 32'h0; PWDATA <= 32'h0;
    end
  endtask

  task apb_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge PCLK);
      PADDR <= addr; PWRITE <= 1'b0; PSEL <= 1'b1; PENABLE <= 1'b0;
      @(posedge PCLK);
      PENABLE <= 1'b1;
      #1 data = PRDATA;
      @(posedge PCLK);
      PSEL <= 1'b0; PENABLE <= 1'b0; PADDR <= 32'h0;
    end
  endtask

  initial begin
    repeat (4) @(posedge PCLK);
    PRESETn = 1'b1;
    repeat (2) @(posedge PCLK);

    apb_write(KEY0 + 32'h00, 32'h00010203);
    apb_write(KEY0 + 32'h04, 32'h04050607);
    apb_write(KEY0 + 32'h08, 32'h08090a0b);
    apb_write(KEY0 + 32'h0c, 32'h0c0d0e0f);
    apb_write(NONCE_DIR, 32'h10203000);
    apb_write(SEQ_HI, 32'h00000000);
    apb_write(SEQ_LO, 32'h00000001);
    apb_write(LEN, 32'h00000010);
    apb_write(PAYLOAD_IN0 + 32'h00, 32'h10010000);
    apb_write(PAYLOAD_IN0 + 32'h04, 32'h00000000);
    apb_write(PAYLOAD_IN0 + 32'h08, 32'h00000000);
    apb_write(PAYLOAD_IN0 + 32'h0c, 32'h00000000);

    apb_write(CTRL, 32'h00000004);
    apb_write(CTRL, 32'h00000001);

    timeout = 0;
    rdata = 32'h0;
    while (((rdata & 32'h2) == 32'h0) && timeout < 200) begin
      apb_read(STATUS, rdata);
      timeout = timeout + 1;
    end

    if ((rdata & 32'h6) != 32'h6) begin
      $display("SUMMARY: FAIL status=0x%08x timeout=%0d", rdata, timeout);
      $finish;
    end

    apb_read(PAYLOAD_OUT0 + 32'h00, ct[127:96]);
    apb_read(PAYLOAD_OUT0 + 32'h04, ct[95:64]);
    apb_read(PAYLOAD_OUT0 + 32'h08, ct[63:32]);
    apb_read(PAYLOAD_OUT0 + 32'h0c, ct[31:0]);
    apb_read(TAG_OUT0 + 32'h00, tag[127:96]);
    apb_read(TAG_OUT0 + 32'h04, tag[95:64]);
    apb_read(TAG_OUT0 + 32'h08, tag[63:32]);
    apb_read(TAG_OUT0 + 32'h0c, tag[31:0]);

    $display("CT=%032x", ct);
    $display("TAG=%032x", tag);

    if (ct !== EXPECTED_CT) begin
      $display("SUMMARY: FAIL ciphertext mismatch");
      $finish;
    end
    if (tag !== EXPECTED_TAG) begin
      $display("SUMMARY: FAIL tag mismatch");
      $finish;
    end

    $display("SUMMARY: PASS");
    $finish;
  end
endmodule
