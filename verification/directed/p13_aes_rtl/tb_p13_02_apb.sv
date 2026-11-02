`timescale 1ns/1ps
module tb_p13_02_apb;
  localparam [31:0] BASE=32'h40040000;
  localparam [127:0] PT=128'h101112131415161718191a1b1c1d1e1f;
  localparam [127:0] CT=128'h5b201b5dd74bb9d8aee94da16ba16356;
  localparam [127:0] TAG=128'h9ee8eb4a087279dac5f75d8e930d5f69;
  reg PCLK=0, PRESETn=0;
  reg [31:0] PADDR=0, PWDATA=0;
  reg PWRITE=0,PSEL=0,PENABLE=0;
  wire [31:0] PRDATA;
  wire PREADY;
  wire [31:0] observed;
  reg completed=0;
  reg lock_inputs=0;
  integer fault_site=0;
  integer i,k,n,activity=0,reset_edges=0,mark,reset_mark,bval_seen=0;
  reg [15:0] expected_bval=0;
  reg check_bval=0;
  reg [31:0] v,w,stat;
  reg [127:0] got_payload,got_tag;
  reg [31:0] lengths[0:8];
  reg [31:0] commands[0:4];
  always #5 PCLK=~PCLK;
  apb_aes_gcm dut(.*);
  p13_02_contract_checker checker_u(PCLK,PRESETn,PSEL,PENABLE,PWRITE,lock_inputs,PADDR,PWDATA);
`ifdef P13_FIXTURE
  p13_observation_fault_adapter adapter(PCLK,PSEL,PENABLE,PWRITE,PRDATA,fault_site,observed);
`else
  assign observed=PRDATA;
`endif
  // Passive interface diagnostics; never used as expected crypto values.
  always @(posedge PCLK) if (PRESETn) begin
    if (dut.core_soft_reset_reg) reset_edges=reset_edges+1;
    if (dut.core_soft_reset_reg || dut.core_key_word_val_reg!=0 || dut.core_iv_val_reg ||
        dut.core_icb_start_reg || dut.core_icb_stop_reg || dut.core_ghash_pkt_val_reg ||
        dut.core_data_in_bval_reg!=0) activity=activity+1;
    if (check_bval && dut.core_data_in_bval_reg!=0) begin
      checker_u.check32("LEN_BYTE_VALID",{16'b0,dut.core_data_in_bval_reg},{16'b0,expected_bval});
      bval_seen=bval_seen+1;
    end
  end
  task wr_abs(input [31:0] addr,data);
    begin
      @(negedge PCLK); PADDR=addr; PWDATA=data; PWRITE=1; PSEL=1; PENABLE=0;
      @(negedge PCLK); PENABLE=1;
      @(negedge PCLK); PSEL=0; PENABLE=0; PWRITE=0; PADDR=0; PWDATA=0;
    end
  endtask
  task wr(input [31:0] off,data);
    begin wr_abs(BASE+off,data); end
  endtask
  task rd_abs(input [31:0] addr, output [31:0] data);
    begin
      @(negedge PCLK); PADDR=addr; PWRITE=0; PSEL=1; PENABLE=0;
      @(negedge PCLK); PENABLE=1;
      #1 data=observed;
      checker_u.require_true("PREADY_ALWAYS",PREADY===1'b1);
      @(negedge PCLK); PSEL=0; PENABLE=0; PADDR=0;
    end
  endtask
  task rd(input [31:0] off,output [31:0] data);
    begin rd_abs(BASE+off,data); end
  endtask
  task expect_reg(input string id,input [31:0] off,want);
    begin rd(off,v); checker_u.check32(id,v,want); end
  endtask
  task wait_terminal;
    integer polls;
    begin
      stat=0; polls=0;
      while (!stat[1] && polls<1000) begin rd('h10,stat); polls=polls+1; end
      checker_u.require_true("TERMINAL_BOUNDED",stat[1] && !stat[0]);
      lock_inputs=0;
    end
  endtask
  task complete_crypto;
    begin
`ifdef P13_FIXTURE
      repeat(20) @(negedge PCLK);
      dut.u_aes_gcm.respond(0,1,1,CT,TAG);
`endif
      wait_terminal();
    end
  endtask
  task program_case(input integer bytes_n,input bit dec,input [127:0] in_data,want_tag);
    begin
      wr('h0c,4);
      for(integer a=0;a<4;a=a+1) wr('h20+4*a,32'h00010203+32'h04040404*a);
      wr('h30,32'h10203000); wr('h34,0); wr('h38,1); wr('h3c,bytes_n);
      for(integer a=0;a<4;a=a+1) begin
        wr('h40+4*a,in_data[127-a*32 -: 32]); wr('h50+4*a,want_tag[127-a*32 -: 32]);
      end
    end
  endtask
  task start_crypto(input bit dec);
    begin wr('h0c,dec?3:1); lock_inputs=1; end
  endtask
  task read_result;
    begin
      for(integer a=0;a<4;a=a+1) begin
        rd('h60+4*a,got_payload[127-a*32 -: 32]); rd('h70+4*a,got_tag[127-a*32 -: 32]);
      end
    end
  endtask
  task kat(input string id,input integer bytes_n,input bit dec,input [127:0] in_data,want_data,want_tag);
    reg [127:0] mask;
    begin
      program_case(bytes_n,dec,in_data,want_tag); start_crypto(dec); wait_terminal();
      checker_u.check32({"KAT_STATUS_",id},stat,6);
      read_result();
      mask=bytes_n==0?0:({128{1'b1}} << ((16-bytes_n)*8));
      checker_u.check128({"KAT_PAYLOAD_",id},got_payload,want_data,mask);
      checker_u.check128({"KAT_TAG_",id},got_tag,want_tag,{128{1'b1}});
      $display("KAT_PASS %0s len=%0d decrypt=%0b",id,bytes_n,dec);
    end
  endtask
  task zeroize;
    begin
      reset_mark=reset_edges;
      wr('h0c,8); lock_inputs=1;
      expect_reg("ZEROIZE_MAINTENANCE",'h10,'h2001);
      repeat(5) @(negedge PCLK);
      lock_inputs=0;
      expect_reg("ZEROIZE_DONE",'h10,0);
      checker_u.require_true("ZEROIZE_REAL_RESET_WIDTH",reset_edges-reset_mark>=2);
      for(integer a=0;a<16;a=a+1) expect_reg("ZEROIZE_INPUT",'h20+a*4,0);
      for(integer a=0;a<12;a=a+1) expect_reg("ZEROIZE_OUTPUT_HDR",'h60+a*4,0);
      expect_reg("ZEROIZE_DIRECTION",'h0c,0);
      checker_u.check128("ZEROIZE_HELD_KEY",dut.core_key_word_reg[255:128],0,{128{1'b1}});
      checker_u.check128("ZEROIZE_HELD_DATA",dut.core_data_in_reg,0,{128{1'b1}});
      checker_u.check128("ZEROIZE_HELD_AAD",dut.core_ghash_aad_reg,0,{128{1'b1}});
      checker_u.check128("ZEROIZE_HELD_IV",{32'b0,dut.core_iv_reg},0,{128{1'b1}});
    end
  endtask
  initial begin
`ifdef P13_FIXTURE
    $display("LANE CONTROL_FIXTURE_ONLY");
`else
    $display("LANE ACTUAL_CORE_KAT");
`endif
    lengths[0]=0;lengths[1]=1;lengths[2]=7;lengths[3]=15;lengths[4]=16;
    lengths[5]=17;lengths[6]=65535;lengths[7]=65536;lengths[8]=65552;
    commands[0]=2;commands[1]=5;commands[2]=9;commands[3]=32'h80000000;commands[4]=12;
    repeat(5) @(negedge PCLK); PRESETn=1;
    repeat(3) @(negedge PCLK);
    expect_reg("RESET_STATUS",'h10,0); expect_reg("NAME0",0,32'h6170622d);
    expect_reg("NAME1",4,32'h67636d20); expect_reg("VERSION",8,32'h322e3030);
    checker_u.check32("RESET_NO_CORE_ACTIVATION",activity,0);
    $display("CASE_PASS RTL-01");

    // One canonical address representation. Every invalid write must leave
    // all programming words and STATUS unchanged, and emit no core pulse.
    program_case(16,0,PT,TAG);
    mark=activity;
    for(i=0;i<8;i=i+1) begin
      case(i)
        0:w=32'h0000000c; 1:w=BASE+'h10c; 2:w=BASE+'h114;
        3:w=32'h5004000c; 4:w=BASE+'h14; 5:w=BASE+'h90;
        6:w=BASE+'h0d; 7:w=BASE+'h10020;
      endcase
      wr_abs(w,1);
      fault_site=1; rd_abs(w,v); checker_u.check32("ALIAS_RAZ",v,0); fault_site=0;
      expect_reg("ALIAS_NO_STATUS",'h10,0);
      for(k=0;k<16;k=k+1) begin rd('h20+k*4,v); checker_u.check_programmed("ALIAS_NO_MUTATION",k,v); end
    end
    checker_u.check32("ALIAS_NO_CORE",activity,mark);
    wr(0,32'hffffffff); expect_reg("CANONICAL_RO_WRITE",0,32'h6170622d);
    $display("CASE_PASS RTL-10");

    for(n=0;n<9;n=n+1) begin
      program_case(lengths[n],0,PT,TAG);
      expect_reg("LEN_FULL_READBACK",'h3c,lengths[n]);
      if(lengths[n]>16) begin
        mark=activity; wr('h0c,3);
        expect_reg("LEN_REJECT_STATUS",'h10,'h5a);
        expect_reg("LEN_REJECT_DIRECTION",'h0c,2);
        for(i=0;i<12;i=i+1) expect_reg("LEN_REJECT_OUTPUT_HDR",'h60+i*4,0);
        for(i=0;i<16;i=i+1) begin rd('h20+i*4,v);checker_u.check_programmed("LEN_RETAIN_INPUT",i,v);end
        checker_u.check32("LEN_REJECT_NO_CORE",activity,mark);
      end else begin
        expected_bval=lengths[n]==0?0:(16'hffff << (16-lengths[n]));
        check_bval=1; bval_seen=0;
        start_crypto(0); complete_crypto(); check_bval=0;
        checker_u.check32("LEN_VALID_STATUS",stat,6);
        checker_u.require_true("LEN_VALID_BYTE_PULSE",lengths[n]==0 || bval_seen>0);
        expect_reg("AAD_WORD0",'h80,32'ha55a1020);
        expect_reg("AAD_WORD1",'h84,32'h30000000);
        expect_reg("AAD_WORD2",'h88,0);
        expect_reg("AAD_WORD3",'h8c,32'h10000|lengths[n]);
      end
    end
    $display("CASE_PASS RTL-02");

    for(i=0;i<5;i=i+1) begin
      wr('h0c,4); mark=activity;
      wr('h0c,commands[i]); expect_reg("MALFORMED_CTRL",'h10,'h428);
      expect_reg("CTRL_DIRECTION_RETAIN",'h0c,2);
      checker_u.check32("MALFORMED_NO_CORE",activity,mark);
    end
    wr('h0c,0); expect_reg("CTRL_ZERO_NOOP",'h10,'h428);
    wr('h0c,4); expect_reg("CLR_ALL",'h10,0); expect_reg("CLR_DIRECTION",'h0c,2);
    $display("CASE_PASS RTL-03");

    // All 16 words: accepted bus history is retained in checker_u.programmed.
    // Each actual-core operation receives a rejected write to one word,
    // including all four live decrypt tag-comparison words.
    for(i=0;i<16;i=i+1) begin
      program_case(16,1,CT,TAG); start_crypto(1);
      wr('h20+i*4,32'hdead0000+i);
      fault_site=2; rd('h20+i*4,v); checker_u.check_programmed("BUSY_IMMUTABLE",i,v); fault_site=0;
      complete_crypto(); checker_u.check32("BUSY_WRITE_OUTCOME",stat,'h22e);
      fault_site=4; read_result(); fault_site=0;
`ifndef P13_FIXTURE
      checker_u.check128("BUSY_DECRYPT_PAYLOAD",got_payload,PT,{128{1'b1}});
`endif
      checker_u.check128("BUSY_TAG_COMPARATOR",got_tag,TAG,{128{1'b1}});
    end
    $display("CASE_PASS RTL-04");

    commands[0]=3;commands[1]=4;commands[2]=8;commands[3]=2;commands[4]=0;
    for(i=0;i<5;i=i+1) begin
      program_case(16,0,PT,TAG); start_crypto(0);
      wr('h0c,commands[i]);
      rd('h10,v);
      case(i)
        0:w='h829; 1:w='h429; 2:w='h1029; 3:w='h429; 4:w=1;
      endcase
      checker_u.check32("BUSY_CTRL_CAUSE",v,w);
      expect_reg("BUSY_DIRECTION",'h0c,0);
      complete_crypto();
      checker_u.check32("BUSY_CTRL_NO_ABORT",stat,(w & ~1)|6);
    end
    $display("CASE_PASS RTL-05");

    // Sticky program causes survive a new accepted START and STATUS reads;
    // operation causes clear on START. Wrong-tag is an independent negative.
    program_case(16,1,CT,TAG^128'b1); start_crypto(1); complete_crypto();
    checker_u.check32("AUTH_FAIL_STATUS",stat,'h9a);
    wr('h0c,2); expect_reg("CAUSE_OR",'h10,'h4ba); expect_reg("STATUS_NO_CLEAR",'h10,'h4ba);
    wr('h50, TAG[127:96]); wr('h5c,TAG[31:0]);
    start_crypto(1); complete_crypto(); checker_u.check32("START_CLEARS_OP_ONLY",stat,'h42e);
    wr('h0c,4); expect_reg("CLR_CAUSES",'h10,0); expect_reg("CLR_KEEPS_DIRECTION",'h0c,2);
    read_result(); checker_u.check128("CLR_KEEPS_OUTPUT_TAG",got_tag,TAG,{128{1'b1}});
    $display("CASE_PASS RTL-06");

`ifdef P13_FIXTURE
    // Deliberately align accepted APB write with the *terminal* edge. The
    // fixture drives callbacks one cycle earlier; no DUT state is overwritten.
    program_case(16,0,PT,TAG); start_crypto(0); repeat(20) @(negedge PCLK);
    dut.u_aes_gcm.respond(0,1,1,CT,TAG);
    PADDR=BASE+'h20; PWDATA=32'hbad; PSEL=1; PWRITE=1; PENABLE=0;
    @(negedge PCLK); PENABLE=1;
    @(negedge PCLK); PSEL=0;PENABLE=0;PWRITE=0;lock_inputs=0;
    expect_reg("SAME_EDGE_DONE_MISUSE",'h10,'h22e);
    // Earliest next edge after completion accepts START, no cleanup bubble.
    wr('h0c,4);
    start_crypto(0); repeat(20) @(negedge PCLK); dut.u_aes_gcm.respond(0,1,1,CT,TAG);
    @(negedge PCLK); PADDR=BASE+'h0c;PWDATA=1;PSEL=1;PWRITE=1;PENABLE=0;
    @(negedge PCLK); PENABLE=1;
    @(negedge PCLK); PSEL=0;PENABLE=0;PWRITE=0;
    expect_reg("BACK_TO_BACK_ADMISSION",'h10,1);
    complete_crypto();checker_u.check32("BACK_TO_BACK_COMPLETE",stat,6);
    $display("CASE_PASS RTL-07");
`else
    $display("CASE_DEFER RTL-07 CONTROL_FIXTURE_ONLY");
`endif

    zeroize();
`ifdef P13_FIXTURE
    @(negedge PCLK); dut.u_aes_gcm.respond(0,1,1,CT,TAG);
`endif
    repeat(10) @(negedge PCLK);
    expect_reg("ZEROIZE_LATE_IGNORED",'h10,0);
    for(i=0;i<12;i=i+1) expect_reg("ZEROIZE_NO_REVIVAL",'h60+i*4,0);
    // Rejected ZEROIZE during maintenance must not restart reset/abort it.
    wr('h0c,8); lock_inputs=1; wr('h0c,8);
    repeat(5) @(negedge PCLK); lock_inputs=0;
    expect_reg("ZEROIZE_DURING_MAINT_REJECT",'h10,'h1028);
    wr('h0c,4);
    $display("CASE_PASS RTL-08");

`ifdef P13_FIXTURE
    for(i=0;i<2;i=i+1) begin
      program_case(16,0,PT,TAG); start_crypto(0);repeat(20) @(negedge PCLK);
      if(i==1) begin
        // Preload successful callbacks; overflow overlaps terminal decision.
        dut.u_aes_gcm.respond(0,1,1,CT,TAG); @(negedge PCLK);
      end
      reset_mark=reset_edges;
      dut.u_aes_gcm.respond(1,1,1,CT,TAG);
      wait_terminal();
      fault_site=3; expect_reg("OVERFLOW_TERMINAL",'h10,'h11a);fault_site=0;
      checker_u.require_true("OVERFLOW_RESET_WIDTH",reset_edges-reset_mark>=2);
      @(negedge PCLK);dut.u_aes_gcm.respond(0,1,1,CT,TAG);
      repeat(8) @(negedge PCLK);
      expect_reg("OVERFLOW_LATE_STATUS",'h10,'h11a);
      for(k=0;k<8;k=k+1) expect_reg("OVERFLOW_NO_REVIVAL",'h60+4*k,0);
      start_crypto(0);complete_crypto();checker_u.check32("OVERFLOW_READMISSION",stat,6);
    end
    $display("CASE_PASS RTL-09");
    $display("CASE_PASS RTL-12 CONTROL_PASS");
`else
    $display("CASE_DEFER RTL-09 CONTROL_FIXTURE_ONLY");
    kat("E0",0,0,0,0,128'h62344254fcd95e1ec42b27bf38efba1c);
    kat("D0",0,1,0,0,128'h62344254fcd95e1ec42b27bf38efba1c);
    kat("E7",7,0,128'h10111213141516000000000000000000,128'h5b201b5dd74bb9000000000000000000,128'he39af015075d18019e78e344b285d1ec);
    kat("D7",7,1,128'h5b201b5dd74bb9000000000000000000,128'h10111213141516000000000000000000,128'he39af015075d18019e78e344b285d1ec);
    kat("E16",16,0,PT,CT,TAG);
    kat("D16",16,1,CT,PT,TAG);
    $display("CASE_PASS RTL-11 ACTUAL_CORE_KAT");
`endif
    $display("SUMMARY_PASS checks=%0d",checker_u.checks);
    completed=1;
    $finish;
  end
  initial begin #2000000; $fatal(1,"TIMEOUT"); end
endmodule
