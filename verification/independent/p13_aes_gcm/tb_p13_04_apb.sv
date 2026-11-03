`timescale 1ns/1ps
module tb_p13_04_apb;
  localparam [31:0] BASE=32'h40040000;
  reg PCLK=0, PRESETn=0, PWRITE=0,PSEL=0,PENABLE=0;
  reg [31:0] PADDR=0,PWDATA=0;
  wire [31:0] PRDATA;
  wire PREADY;
  reg completed=0,locked=0,track_op=0;
  reg [31:0] v,stat,addr,w;
  reg [127:0] key,pt,ct,tag,aad,got,got_tag,mask;
  reg [95:0] iv;
  integer fd,parsed,vec,n,i,j,d,case_count=0,cycle=0,start_cycle=0,done_cycle=0;
  integer activity=0,reset_edges=0,mark,rmark,latency,reference_latency,prior_done;
  integer invalid_len[0:3];
  integer commands[0:7];
  string vectors_path;
  always #5 PCLK=~PCLK;
  apb_aes_gcm dut(.*);
  p13_04_contract_scoreboard score(PCLK,PRESETn,PSEL,PENABLE,PWRITE,locked,PADDR,PWDATA);

  // Passive observations only. No internal driver/force/deposit anywhere.
  // Latency is measured from accepted external START to observed terminal edge.
  always @(posedge PCLK) begin
    cycle=cycle+1;
    if (PRESETn) begin
      if (dut.core_soft_reset_reg) reset_edges=reset_edges+1;
      if (dut.core_soft_reset_reg || dut.core_key_word_val_reg!=0 || dut.core_iv_val_reg ||
          dut.core_icb_start_reg || dut.core_icb_stop_reg || dut.core_ghash_pkt_val_reg ||
          dut.core_ghash_aad_bval_reg!=0 || dut.core_data_in_bval_reg!=0) activity=activity+1;
      if (track_op && !locked && PSEL && PENABLE && PWRITE && PADDR==BASE+'hc && (PWDATA==1 || PWDATA==3)) begin
        start_cycle=cycle; done_cycle=0;
      end
    end
    #1;
    if (PRESETn && track_op && done_cycle==0 && dut.done_reg===1'b1) begin
      done_cycle=cycle;
      $display("TIMING start_cycle=%0d done_cycle=%0d latency=%0d",start_cycle,done_cycle,done_cycle-start_cycle);
    end
  end
  task wr_abs(input [31:0] a,data);
    begin
      @(negedge PCLK); PADDR=a; PWDATA=data; PWRITE=1;PSEL=1;PENABLE=0;
      @(negedge PCLK); PENABLE=1;
      @(negedge PCLK); PSEL=0;PENABLE=0;PWRITE=0;PADDR=0;PWDATA=0;
    end
  endtask
  task wr(input [31:0] off,data); begin wr_abs(BASE+off,data); end endtask
  task rd_abs(input [31:0] a,output [31:0] data);
    begin
      @(negedge PCLK);PADDR=a;PWRITE=0;PSEL=1;PENABLE=0;
      @(negedge PCLK);PENABLE=1;
      #1; data=PRDATA; score.require_true("PREADY_ALWAYS",PREADY===1'b1);
      if(a==BASE+'h10) score.status_summary(data);
      @(negedge PCLK);PSEL=0;PENABLE=0;PADDR=0;
    end
  endtask
  task rd(input [31:0] off,output [31:0] data); begin rd_abs(BASE+off,data);end endtask
  task expect_reg(input string id,input [31:0] off,expected);
    begin rd(off,v);score.check32(id,v,expected);end
  endtask
  task program_case(input integer len,input reg [127:0] payload,auth);
    integer k;
    begin
      locked=0;wr('hc,4);
      for(k=0;k<4;k=k+1) wr('h20+4*k,key[127-32*k -:32]);
      for(k=0;k<3;k=k+1) wr('h30+4*k,iv[95-32*k -:32]);
      wr('h3c,len);
      for(k=0;k<4;k=k+1) wr('h40+4*k,payload[127-32*k -:32]);
      for(k=0;k<4;k=k+1) wr('h50+4*k,auth[127-32*k -:32]);
      expect_reg("PROGRAM_STATUS",'h10,0);
    end
  endtask
  task start_crypto(input integer decrypt);
    begin
      track_op=1; wr('hc,decrypt?3:1); locked=1;
    end
  endtask
  task finish_crypto;
    integer polls;
    begin
      polls=0;stat=0;
      while(!stat[1] && polls<1000) begin rd('h10,stat);polls=polls+1;end
      score.require_true("TERMINAL_BOUNDED",stat[1] && !stat[0]);
      score.require_true("ACTUAL_LATENCY",done_cycle>start_cycle);
      latency=done_cycle-start_cycle;locked=0;track_op=0;
    end
  endtask
  task results;
    integer k;
    begin
      for(k=0;k<4;k=k+1) begin rd('h60+4*k,v);got[127-32*k -:32]=v;end
      for(k=0;k<4;k=k+1) begin rd('h70+4*k,v);got_tag[127-32*k -:32]=v;end
    end
  endtask
  task input_readbacks(input string id);
    integer k;
    begin for(k=0;k<16;k=k+1) begin rd('h20+4*k,v);score.check32(id,v,score.programmed[k]);end end
  endtask
  task all_zero;
    integer k;
    begin for(k=0;k<28;k=k+1) expect_reg("SENSITIVE_ZERO",'h20+4*k,0);end
  endtask
  task system_reset;
    begin
      @(negedge PCLK); PRESETn=0;PSEL=0;PENABLE=0;PWRITE=0;track_op=0;locked=0;
      repeat(4) @(negedge PCLK);
      PRESETn=1;repeat(3) @(negedge PCLK);
      expect_reg("RESET_STATUS",'h10,0);expect_reg("RESET_DIRECTION",'hc,0);all_zero();
    end
  endtask
  task crypto_compare(input integer decrypt,input [31:0] expected_status);
    begin
      finish_crypto();score.check32("CRYPTO_STATUS",stat,expected_status);results();
      mask=n==0 ? 0 : ({128{1'b1}} << (8*(16-n)));
      score.check128(decrypt?"ORACLE_PLAINTEXT":"ORACLE_CIPHERTEXT",got,decrypt?pt:ct,mask);
      score.check128("ORACLE_TAG",got_tag,tag,{128{1'b1}});
    end
  endtask
  initial begin
    invalid_len[0]=17;invalid_len[1]=65535;invalid_len[2]=65536;invalid_len[3]=65552;
    commands[0]=2;commands[1]=5;commands[2]=9;commands[3]=12;
    commands[4]=32'h80000000;commands[5]=6;commands[6]=7;commands[7]=15;
    system_reset();expect_reg("VERSION",8,32'h322e3030);
    if(!$value$plusargs("vectors=%s",vectors_path)) $fatal(1,"VECTOR_PATH_REQUIRED");
    fd=$fopen(vectors_path,"r");score.require_true("VECTOR_FILE_OPEN",fd!=0);
    for(j=0;j<34;j=j+1) begin
      parsed=$fscanf(fd,"%d %d %h %h %h %h %h %h\n",vec,n,key,iv,pt,ct,tag,aad);
      score.require_true("VECTOR_RECORD",parsed==8 && vec==j && n==j%17);
      for(d=0;d<2;d=d+1) begin
        $display("CASE_BEGIN vector=%0d direction=%0d len=%0d",vec,d,n);
        program_case(n,d?ct:pt,tag);expect_reg("LEN_READBACK",'h3c,n);
        start_crypto(d);crypto_compare(d,6);
        for(i=0;i<4;i=i+1) expect_reg("AAD_PACKING",'h80+4*i,aad[127-32*i -:32]);
        $display("CRYPTO_CASE vector=%0d direction=%0d len=%0d payload=%032h tag=%032h status=%08h latency=%0d start=%0d done=%0d",vec,d,n,got,got_tag,stat,latency,start_cycle,done_cycle);
        case_count=case_count+1;
      end
    end
    $fclose(fd);score.check32("ALL_LEN_ED_COUNT",case_count,68);
    $display("CASE_PASS DV04-02");$display("CASE_PASS DV04-03");$display("CASE_PASS DV04-04");$display("CASE_PASS DV04-11");
    // Last vector is asymmetric, LEN16. Four real external tamper cases.
    for(i=0;i<4;i=i+1) begin
      program_case(16,ct,tag);
      case(i)
        0:wr('h5c,tag[31:0]^1);
        1:wr('h40,ct[127:96]^32'h80000000);
        2:wr('h34,iv[63:32]^1); // changes actual IV and fixed AAD
        3:wr('h3c,15); // changes authenticated AAD length + valid payload length
      endcase
      start_crypto(1);finish_crypto();score.check32("AUTH_FAIL_STATUS",stat,'h9a);
      $display("NEGATIVE_CASE AUTH_%0d status=%08h",i,stat);
    end
    $display("CASE_PASS DV04-05");
    // Seed stale output before every full-width LEN rejection.
    for(i=0;i<4;i=i+1) begin
      program_case(16,pt,tag);start_crypto(0);crypto_compare(0,6);
      wr('h3c,invalid_len[i]);expect_reg("FULL_LEN_STORAGE",'h3c,invalid_len[i]);
      mark=activity;wr('hc,3);repeat(5) @(negedge PCLK);
      expect_reg("LEN_ERROR_STATUS",'h10,'h5a);expect_reg("INVALID_DIRECTION",'hc,2);
      for(d=0;d<12;d=d+1) expect_reg("INVALID_STALE_CLEAR",'h60+4*d,0);
      score.check32("INVALID_NO_CORE_ACTIVATION",activity,mark);input_readbacks("INVALID_INPUT_RETAINED");
    end
    $display("CASE_PASS DV04-06");
    for(i=0;i<8;i=i+1) begin
      wr('hc,4);mark=activity;wr('hc,commands[i]);expect_reg("MALFORMED_STATUS",'h10,'h428);
      expect_reg("MALFORMED_DIRECTION",'hc,2);score.check32("MALFORMED_NO_CORE",activity,mark);
      input_readbacks("MALFORMED_INPUTS_RETAINED");
    end
    wr('hc,0);expect_reg("IDLE_ZERO_NOOP",'h10,'h428);
    // All 16 protected words attempted during separate genuine decrypts.
    for(i=0;i<16;i=i+1) begin
      program_case(16,ct,tag);start_crypto(1);wr('h20+4*i,32'hdead0000+i);
      rd('h20+4*i,v);score.check32("BUSY_IMMUTABLE",v,score.programmed[i]);
      crypto_compare(1,'h22e);input_readbacks("BUSY_ALL_INPUTS_RETAINED");
      $display("NEGATIVE_CASE BUSY_WORD_%0d status=%08h",i,stat);
    end
    for(i=0;i<5;i=i+1) begin
      program_case(16,pt,tag);start_crypto(0);
      case(i)
        0:begin w=3;v='h829;end
        1:begin w=4;v='h429;end
        2:begin w=8;v='h1029;end
        3:begin w=2;v='h429;end
        4:begin w=0;v=1;end
      endcase
      wr('hc,w);rd('h10,stat);score.check32("BUSY_COMMAND_STATUS",stat,v);
      crypto_compare(0,(v & ~1)|6);
      expect_reg("BUSY_COMMAND_DIRECTION",'hc,0);input_readbacks("BUSY_COMMAND_INPUTS_RETAINED");
    end
    // New START clears operation cause but preserves programming misuse.
    program_case(16,ct,tag^128'b1);start_crypto(1);finish_crypto();
    score.check32("STICKY_AUTH_INITIAL",stat,'h9a);wr('hc,2);
    expect_reg("STICKY_CAUSE_OR",'h10,'h4ba);expect_reg("STATUS_READ_PRESERVES",'h10,'h4ba);
    wr('h5c,tag[31:0]);start_crypto(1);crypto_compare(1,'h42e);
    mark=activity;wr('hc,4);expect_reg("CLR_STATUS_ONLY",'h10,0);expect_reg("CLR_DIRECTION",'hc,2);
    results();score.check128("CLR_OUTPUT_RETAINED",got,pt,{128{1'b1}});
    score.check128("CLR_TAG_RETAINED",got_tag,tag,{128{1'b1}});input_readbacks("CLR_INPUT_RETAINED");
    for(i=0;i<4;i=i+1) expect_reg("CLR_HDR_RETAINED",'h80+4*i,aad[127-32*i -:32]);
    score.check32("CLR_NO_CORE_RESET",activity,mark);
    // Race timing comes from measured prior real-core latency, no state override.
    program_case(16,pt,tag);start_crypto(0);crypto_compare(0,6);reference_latency=latency;
    program_case(16,pt,tag);start_crypto(0);
    while(cycle<start_cycle+reference_latency-2) @(negedge PCLK);
    PADDR=BASE+'h20;PWDATA=32'hbad;PSEL=1;PWRITE=1;PENABLE=0;
    @(negedge PCLK);PENABLE=1;
    @(negedge PCLK);
    score.require_true("SAME_EDGE_ALIGNMENT",cycle==start_cycle+reference_latency && done_cycle==cycle);
    PSEL=0;PENABLE=0;PWRITE=0;crypto_compare(0,'h22e);
    expect_reg("SAME_EDGE_WORD_RETAINED",'h20,key[127:96]);
    // Earliest back-to-back APB START after a terminal-edge rejected START.
    wr('hc,4);start_crypto(0);
    while(cycle<start_cycle+reference_latency-2) @(negedge PCLK);
    PADDR=BASE+'hc;PWDATA=3;PSEL=1;PWRITE=1;PENABLE=0;
    @(negedge PCLK);PENABLE=1;
    @(negedge PCLK);
    score.require_true("TERMINAL_START_REJECT_ALIGNMENT",done_cycle==cycle);
    prior_done=done_cycle;
    // New SETUP immediately after terminal ACCESS; no internal state override.
    PADDR=BASE+'hc;PWDATA=1;PSEL=1;PWRITE=1;PENABLE=0;locked=0;
    @(negedge PCLK);PENABLE=1;
    @(negedge PCLK);PSEL=0;PENABLE=0;PWRITE=0;locked=1;
    score.check32("EARLIEST_APB_READMISSION",start_cycle,prior_done+2);
    crypto_compare(0,'h82e);
    $display("CASE_PASS DV04-07");
    // Accepted IDLE zeroize: actual reset pulse, full readback and quiet window.
    wr('hc,4);rmark=reset_edges;wr('hc,8);locked=1;
    rd('h10,stat);score.check32("ZEROIZE_ACTIVE",stat,'h2001);
    repeat(5) @(negedge PCLK);locked=0;
    expect_reg("ZEROIZE_COMPLETE",'h10,0);expect_reg("ZEROIZE_DIRECTION",'hc,0);
    score.require_true("ZEROIZE_REAL_RESET_WIDTH",reset_edges-rmark>=2);all_zero();
    repeat(100) @(negedge PCLK);expect_reg("ZEROIZE_NO_LATE_STATUS",'h10,0);all_zero();
    for(i=0;i<2;i=i+1) begin
      program_case(16,pt,tag);start_crypto(0);
      if(i==1) begin finish_crypto();end else repeat(10) @(negedge PCLK);
      system_reset();repeat(100) @(negedge PCLK);expect_reg("RESET_NO_REVIVAL",'h10,0);all_zero();
    end
    $display("CASE_PASS DV04-08");
    program_case(16,pt,tag);mark=activity;
    // Full address aliases, reserved, unaligned and truncated-base accesses.
    for(i=0;i<10;i=i+1) begin
      case(i)
        0:addr=32'hc;1:addr=BASE+'h10c;2:addr=BASE+'h120;
        3:addr=32'h5004000c;4:addr=BASE+'h14;5:addr=BASE+'h90;
        6:addr=BASE+'hd;7:addr=BASE+'h10020;8:addr=BASE+'h11c;9:addr=32'hc0040020;
      endcase
      wr_abs(addr,1);rd_abs(addr,v);score.check32("ALIAS_RAZ_WI",v,0);
      expect_reg("ALIAS_STATUS_UNCHANGED",'h10,0);input_readbacks("ALIAS_INPUT_UNCHANGED");
    end
    score.check32("ALIAS_NO_CORE",activity,mark);
    for(i=0;i<3;i=i+1) begin wr(4*i,32'hffffffff);end
    expect_reg("RO_NAME0",0,32'h6170622d);expect_reg("RO_NAME1",4,32'h67636d20);
    expect_reg("RO_VERSION",8,32'h322e3030);
    for(i=0;i<12;i=i+1) wr('h60+4*i,32'hffffffff);
    wr('h10,32'hffffffff);expect_reg("RO_STATUS_WRITE",'h10,0);all_output_zero();
    $display("CASE_PASS DV04-09");
    $display("CASE_NOT_RUN DV04-10 NATURAL_32BIT_ICB_OVERFLOW");
    $display("SUMMARY_PASS cases=%0d checks=%0d",case_count,score.checks);completed=1;$finish;
  end
  task all_output_zero;
    integer k;
    begin for(k=0;k<12;k=k+1) expect_reg("RO_WRITE_IGNORED",'h60+4*k,0);end
  endtask
  initial begin #3000000; $fatal(1,"TIMEOUT");end
endmodule
