`timescale 1ns/1ps
module tb_p09_gsensor_cpu_e2e;
  reg clk=0; reg [1:0] KEY=2'b10; reg [9:0] SW=0; reg [2:1] G_SENSOR_INT=0;
  reg G_SENSOR_SDO=0, lora_rx=1, lora_aux=0, uart_rx=1;
  wire [9:0] LEDR; wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5; wire G_SENSOR_CS_N,G_SENSOR_SCLK,G_SENSOR_SDI;
  wire [3:0] VGA_R,VGA_G,VGA_B; wire VGA_HS,VGA_VS,lora_tx,uart_tx;
  integer frames=0, reads=0, sig_word, fault_pc, timeout, bitn, i, ledger=0, pre_status_reads=0;
  integer expected_read_cmd, max_pre_status;
  integer fault_accesses=0, error_final_cycles=0;
  reg [55:0] tx; reg [47:0] payload;
  reg [15:0] init[0:11]; reg [7:0] read_cmd;
  reg [31:0] fault_x14_before, sig6_before, sig7_before;
  reg fault_access_seen=0, fault_error_final_seen=0;
  string image;
  always #5 clk=~clk;
  AMBA_SoC_TOP dut(.clk(clk),.KEY(KEY),.SW(SW),.LEDR(LEDR),.HEX0(HEX0),.HEX1(HEX1),.HEX2(HEX2),.HEX3(HEX3),.HEX4(HEX4),.HEX5(HEX5),.G_SENSOR_CS_N(G_SENSOR_CS_N),.G_SENSOR_INT(G_SENSOR_INT),.G_SENSOR_SCLK(G_SENSOR_SCLK),.G_SENSOR_SDI(G_SENSOR_SDI),.G_SENSOR_SDO(G_SENSOR_SDO),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.lora_tx(lora_tx),.lora_rx(lora_rx),.lora_aux(lora_aux),.uart_tx(uart_tx),.uart_rx(uart_rx));
  initial begin
    init[0]=16'h2420;init[1]=16'h2503;init[2]=16'h2601;init[3]=16'h277f;init[4]=16'h2809;init[5]=16'h2946;init[6]=16'h2c09;init[7]=16'h2f00;init[8]=16'h2e80;init[9]=16'h3100;init[10]=16'h2007;init[11]=16'h2d08;
    if (!$value$plusargs("IMEM_HEX=%s", image)) $fatal(1,"missing IMEM_HEX");
    if (!$value$plusargs("SIG_WORD=%d", sig_word)) $fatal(1,"missing SIG_WORD");
    if (!$value$plusargs("FAULT_PC=%h", fault_pc)) $fatal(1,"missing FAULT_PC");
    expected_read_cmd = 8'hf2;
    max_pre_status = 1000;
    if ($value$plusargs("EXPECT_READ_CMD=%h", expected_read_cmd)) begin end
    if ($value$plusargs("MAX_PRE_STATUS=%d", max_pre_status)) begin end
    force dut.PRESETN_SYS=0; #1; $readmemh(image,dut.u_CPU.if_id_register.u_IMEM.words); repeat(4) @(posedge clk); @(negedge clk); force dut.PRESETN_SYS=1;
  end
  always @(posedge clk) begin
    if (dut.u_gsensor.PSEL && dut.u_gsensor.PENABLE && dut.u_gsensor.PREADY) begin
      $display("CHECK APB accepted ledger=%0d addr=%h write=%b wdata=%h pslverr=%b",ledger,dut.u_gsensor.PADDR,dut.u_gsensor.PWRITE,dut.u_gsensor.PWDATA,dut.u_gsensor.PSLVERR);
      case (ledger)
        0: begin
          if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030008 && dut.u_gsensor.PSLVERR===0)
            pre_status_reads = pre_status_reads + 1;
          else if (dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030010 && dut.u_gsensor.PWDATA===32'h1 && dut.u_gsensor.PSLVERR===0)
            ledger = 1;
          else $fatal(1,"APB ledger prelude unexpected addr=%h write=%b wdata=%h pslverr=%b",dut.u_gsensor.PADDR,dut.u_gsensor.PWRITE,dut.u_gsensor.PWDATA,dut.u_gsensor.PSLVERR);
        end
        1: if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030008 && dut.u_gsensor.PSLVERR===0) ledger = 2; else $fatal(1,"APB ledger expected STATUS after CAPTURE");
        2: if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h4003000c && dut.u_gsensor.PSLVERR===0) ledger = 3; else $fatal(1,"APB ledger expected HOLD_SEQ");
        3: if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030000 && dut.u_gsensor.PSLVERR===0) ledger = 4; else $fatal(1,"APB ledger expected HOLD_XY");
        4: if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030004 && dut.u_gsensor.PSLVERR===0) ledger = 5; else $fatal(1,"APB ledger expected HOLD_Z");
        5: if (dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030010 && dut.u_gsensor.PWDATA===32'h2 && dut.u_gsensor.PSLVERR===0) ledger = 6; else $fatal(1,"APB ledger expected RELEASE");
        6: begin
          if (!dut.u_gsensor.PWRITE && dut.u_gsensor.PADDR===32'h40030010 && dut.u_gsensor.PSLVERR===1) begin
            ledger = 7;
            fault_accesses = fault_accesses + 1;
            fault_access_seen = 1'b1;
            fault_x14_before = dut.u_CPU.register_file.registers[14];
            sig6_before = dut.u_memory.u_bram.words[sig_word+6];
            sig7_before = dut.u_memory.u_bram.words[sig_word+7];
            $display("CHECK APB fault access addr=%h write=%b pslverr=%b x14_before=%h sig6_before=%h sig7_before=%h",dut.u_gsensor.PADDR,dut.u_gsensor.PWRITE,dut.u_gsensor.PSLVERR,fault_x14_before,sig6_before,sig7_before);
          end else $fatal(1,"APB ledger expected exactly one WO SNAP_CTRL read fault");
        end
        default: $fatal(1,"APB ledger extra accepted access addr=%h write=%b wdata=%h",dut.u_gsensor.PADDR,dut.u_gsensor.PWRITE,dut.u_gsensor.PWDATA);
      endcase
    end
    if (fault_access_seen && dut.HRESP===2'b01 && dut.HREADY===1'b1) begin
      error_final_cycles = error_final_cycles + 1;
      fault_error_final_seen = 1'b1;
      $display("CHECK AHB error final hresp=%b hready=%b",dut.HRESP,dut.HREADY);
    end
  end
  initial begin : peer
    forever begin
      @(negedge G_SENSOR_CS_N); tx=0;
      if (frames < 12) begin bitn=16; read_cmd=8'h00; end else if (frames == 12) begin bitn=56; read_cmd=expected_read_cmd[7:0]; payload=48'h3412_7856_bc9a; end else $fatal(1,"unexpected SPI frame=%0d",frames);
      for(i=0;i<bitn;i=i+1) begin
        @(negedge G_SENSOR_SCLK);
        if (frames<12 && G_SENSOR_SDI !== init[frames][15-i]) $fatal(1,"init MOSI frame=%0d bit=%0d",frames,i);
        if (frames==12 && G_SENSOR_SDI !== ((i<8) ? read_cmd[7-i] : 1'b0)) $fatal(1,"SPI read MOSI mismatch bit=%0d actual=%b expected=%b command=%02h",i,G_SENSOR_SDI,((i<8) ? read_cmd[7-i] : 1'b0),read_cmd);
        if(frames==12 && i>=8) G_SENSOR_SDO=payload[55-i]; else G_SENSOR_SDO=0;
        @(posedge G_SENSOR_SCLK); tx={tx[54:0],G_SENSOR_SDI};
      end
      @(posedge G_SENSOR_CS_N); frames=frames+1;
      if(frames==13) begin reads=reads+1; $display("CHECK SPI read MOSI command=%02h payload_bits=48 frame_bits=56",read_cmd); end
      if(frames==12) begin repeat(4) @(posedge clk); G_SENSOR_INT[1]=1; end
    end
  end
  initial begin
    for(timeout=0;timeout<200000;timeout=timeout+1) begin @(posedge clk); if(dut.u_CPU.csr_file.mcause==5) begin
      if(dut.u_CPU.csr_file.mepc!==fault_pc) $fatal(1,"fault mepc=%h expected=%h",dut.u_CPU.csr_file.mepc,fault_pc);
      if(frames!=13 || reads!=1) $fatal(1,"SPI lifecycle frames=%0d reads=%0d",frames,reads);
      if(pre_status_reads<1 || pre_status_reads>max_pre_status || ledger!=7 || fault_accesses!=1) $fatal(1,"APB ledger pre_status=%0d max=%0d ledger=%0d faults=%0d",pre_status_reads,max_pre_status,ledger,fault_accesses);
      if(!fault_access_seen || !fault_error_final_seen || error_final_cycles!=1) $fatal(1,"AHB error evidence access=%b final=%b cycles=%0d",fault_access_seen,fault_error_final_seen,error_final_cycles);
      if(dut.u_gsensor.hold_valid!==0) $fatal(1,"HOLD not released");
      if(fault_x14_before!==32'h4f4b0001 || dut.u_CPU.register_file.registers[14]!==fault_x14_before) $fatal(1,"faulting load x14 writeback before=%h after=%h",fault_x14_before,dut.u_CPU.register_file.registers[14]);
      if(sig6_before!==0 || dut.u_memory.u_bram.words[sig_word+6]!==sig6_before) $fatal(1,"signature[6] fault side effect before=%h after=%h",sig6_before,dut.u_memory.u_bram.words[sig_word+6]);
      if(sig7_before!==0 || dut.u_memory.u_bram.words[sig_word+7]!==sig7_before) $fatal(1,"signature[7] younger side effect before=%h after=%h",sig7_before,dut.u_memory.u_bram.words[sig_word+7]);
      if(dut.u_memory.u_bram.words[sig_word+0]!==1 || dut.u_memory.u_bram.words[sig_word+1]!==0 || dut.u_memory.u_bram.words[sig_word+2]!==1 || dut.u_memory.u_bram.words[sig_word+3]!==32'h12345678 || dut.u_memory.u_bram.words[sig_word+4]!==32'h00009abc || dut.u_memory.u_bram.words[sig_word+5]!==32'h4f4b0001) $fatal(1,"pre-fault signature mismatch");
      $display("CHECK fault mcause=%0d mepc=%h",dut.u_CPU.csr_file.mcause,dut.u_CPU.csr_file.mepc);
      $display("SUMMARY: PASS P09 GSensor CPU e2e"); $finish;
    end
    end
    $fatal(1,"timeout pc=%h frames=%0d",dut.u_CPU.pc,frames);
  end
endmodule
