`timescale 1ns/1ps

module tb_p11c_adc_lifecycle_cpu_e2e;
    reg clk = 0;
    reg [1:0] KEY = 2'b11;
    reg [9:0] SW = 10'b0;
    reg [2:1] G_SENSOR_INT = 2'b00;
    reg G_SENSOR_SDO = 0;
    reg lora_rx = 1;
    reg lora_aux = 0;
    wire uart_rx;

    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire G_SENSOR_CS_N, G_SENSOR_SCLK, G_SENSOR_SDI;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire VGA_HS, VGA_VS;
    wire lora_tx, uart_tx;
    wire [15:0] GPIO_IO;

    always #10 clk = ~clk;

    assign uart_rx = lora_tx;
    assign GPIO_IO[1] = GPIO_IO[0];
    assign GPIO_IO[15:2] = 14'bz;

    AMBA_SoC_TOP dut (
        .clk(clk),
        .KEY(KEY),
        .SW(SW),
        .LEDR(LEDR),
        .GPIO_IO(GPIO_IO),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N),
        .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK),
        .G_SENSOR_SDI(G_SENSOR_SDI),
        .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    defparam dut.u_adc_qsys.RESPONSE_LATENCY = 50;

    string imem_hex, dmem_hex;
    integer sig_word_addr = 0;
    integer step_word_addr = 0;
    integer max_cycles = 100000;
    integer cycle = 0;

    // Track state transitions
    integer step_seen = 0;
    reg seen_pslverr = 0;
    reg seen_hresp_error = 0;

    initial begin
        if (!$value$plusargs("IMEM_HEX=%s", imem_hex)) $fatal(1, "Missing +IMEM_HEX");
        if (!$value$plusargs("DMEM_HEX=%s", dmem_hex)) dmem_hex = "";
        if (!$value$plusargs("SIG_WORD=%d", sig_word_addr)) $fatal(1, "Missing +SIG_WORD");
        if (!$value$plusargs("STEP_WORD=%d", step_word_addr)) $fatal(1, "Missing +STEP_WORD");
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin end

        $display("=== P11C-C4-A Dedicated ADC Lifecycle CPU E2E Test ===");
        $display("IMEM_HEX   : %s", imem_hex);
        $display("DMEM_HEX   : %s", dmem_hex);
        $display("SIG_WORD   : %0d", sig_word_addr);
        $display("STEP_WORD  : %0d", step_word_addr);

        force dut.PRESETN_SYS = 0;
        #1;
        $readmemh(imem_hex, dut.u_CPU.if_id_register.u_IMEM.words);
        if (dmem_hex != "") begin
            $readmemh(dmem_hex, dut.u_memory.u_bram.words);
        end
        repeat (10) @(posedge clk);
        @(negedge clk);
        force dut.PRESETN_SYS = 1;
        $display("[LIFECYCLE CPU E2E] Reset released, executing...");
    end

    // Monitor PSLVERR on slot-5 illegal access
    always @(posedge clk) begin
        if (dut.PRESETN_SYS) begin
            cycle = cycle + 1;

            if (dut.u_adc_controller.PSEL && dut.u_adc_controller.PENABLE &&
                dut.u_adc_controller.PREADY && dut.u_adc_controller.PSLVERR) begin
                seen_pslverr = 1;
                $display("[LIFECYCLE MONITOR] APB PSLVERR observed on ADC aperture at cycle %0d (addr=0x%h)",
                         cycle, dut.u_adc_controller.PADDR);
            end

            if (dut.HRESP == 2'b01 && dut.HREADY == 1'b1) begin
                seen_hresp_error = 1;
                $display("[LIFECYCLE MONITOR] AHB HRESP ERROR observed at cycle %0d", cycle);
            end

            // Monitor step progress in DMEM
            if (dut.u_memory.u_bram.words[step_word_addr] != step_seen) begin
                step_seen = dut.u_memory.u_bram.words[step_word_addr];
                $display("[LIFECYCLE PROGRESS] Entered Step %0d at cycle %0d", step_seen, cycle);
            end

            // Check signature for pass or failure
            if (dut.u_memory.u_bram.words[sig_word_addr] == 32'h50313143) begin // "P11C"
                if (!seen_pslverr || !seen_hresp_error)
                    $fatal(1, "[LIFECYCLE FATAL] Completed without verifying PSLVERR/AHB error response!");

                $display("\n========================================================");
                $display("    P11C-C4-A ADC LIFECYCLE CPU E2E VERIFICATION SUMMARY");
                $display("========================================================");
                $display("Step 1: Peripheral identity canonical check      : PASS");
                $display("Step 2: Engine enable & bounded polling          : PASS");
                $display("Step 3: First valid frame capture                : PASS");
                $display("Step 4: Immediate second capture returns NO_NEW  : PASS (Freshness proof)");
                $display("Step 5: Newer frame advances HOLD sequence       : PASS");
                $display("Step 6: Joystick policy matrix across 9 vectors  : PASS (FW vs HW match)");
                $display("Step 7: Engine disable, LIVE cleared, HOLD kept  : PASS (Lifecycle proof)");
                $display("Step 8: Re-enable engine, restart CH1, new frame : PASS");
                $display("Step 9: Error status & clear set-dominance check : PASS");
                $display("Step 10: Illegal slot-5 access trapped & caught  : PASS (PSLVERR -> AHB ERROR)");
                $display("Step 11: Final signature 0x50313143 verified    : PASS");
                $display("========================================================");
                $display("SUMMARY: PASS tb_p11c_adc_lifecycle_cpu_e2e");
                $display("========================================================");
                $finish;
            end else if ((dut.u_memory.u_bram.words[sig_word_addr] & 32'hFFFF0000) == 32'hDEAD0000) begin
                $fatal(1, "[LIFECYCLE FATAL] Test failed at signature 0x%h (step=%0d)",
                       dut.u_memory.u_bram.words[sig_word_addr], step_seen);
            end

            if (cycle >= max_cycles) begin
                $fatal(1, "[LIFECYCLE TIMEOUT] Timeout at cycle %0d, step=%0d, sig=0x%h",
                       cycle, step_seen, dut.u_memory.u_bram.words[sig_word_addr]);
            end
        end
    end

endmodule
