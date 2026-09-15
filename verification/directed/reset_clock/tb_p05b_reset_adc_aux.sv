`timescale 1ns/1ps

module tb_p05b_reset_adc_aux;
    localparam integer RELEASE_CYCLES = 8;

    reg  hclk = 1'b0;
    reg  reset_button_n = 1'b1;
    wire system_reset_n;
    integer last_hclk_posedge;
    integer release_edges;

    reg  adc_clk = 1'b0;
    reg  adc_source_reset_n = 1'b0;
    reg  adc_ready = 1'b0;
    wire adc_reset_n;
    wire adc_valid;
    wire [4:0] adc_channel;
    wire adc_sop;
    wire adc_eop;

    reg  aux_reset_n = 1'b0;
    reg  lora_aux = 1'b0;
    reg  [31:0] paddr = 32'h0000_0004;
    reg  pwrite = 1'b0;
    reg  psel = 1'b1;
    reg  penable = 1'b1;
    reg  [31:0] pwdata = 32'h0;
    wire [31:0] prdata;
    wire lora_tx;
    wire lora_pready;

    always #10 hclk = ~hclk;
    always #20 adc_clk = ~adc_clk;
    always @(posedge hclk) last_hclk_posedge = $time;

    system_reset_controller #(
        .RELEASE_CYCLES (RELEASE_CYCLES),
        .COUNTER_WIDTH  (4)
    ) u_system_reset (
        .clk            (hclk),
        .reset_button_n (reset_button_n),
        .system_reset_n (system_reset_n)
    );

    reset_release_sync u_adc_reset (
        .clk           (adc_clk),
        .async_reset_n (adc_source_reset_n),
        .reset_n       (adc_reset_n)
    );

    adc_command_sequencer u_adc_sequence (
        .clk                    (adc_clk),
        .reset_n                (adc_reset_n),
        .command_ready          (adc_ready),
        .command_valid          (adc_valid),
        .command_channel        (adc_channel),
        .command_startofpacket  (adc_sop),
        .command_endofpacket    (adc_eop)
    );

    APB_UART_LORA u_lora_uart (
        .PCLK      (hclk),
        .PRESETn   (aux_reset_n),
        .PADDR     (paddr),
        .PWRITE    (pwrite),
        .PSEL      (psel),
        .PENABLE   (penable),
        .PWDATA    (pwdata),
        .PRDATA    (prdata),
        .uart_tx   (lora_tx),
        .uart_rx   (1'b1),
        .lora_aux  (lora_aux),
        .PREADY    (lora_pready)
    );

    task automatic check_condition;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $fatal(1);
            end
        end
    endtask

    task automatic wait_system_release;
        begin
            wait (u_system_reset.reset_release_sync === 1'b1);
            release_edges = 0;
            while (system_reset_n !== 1'b1) begin
                @(posedge hclk);
                #1;
                release_edges = release_edges + 1;
            end
            check_condition(release_edges == RELEASE_CYCLES,
                   "system reset qualification length changed");
            check_condition($time - 1 == last_hclk_posedge,
                   "system reset did not deassert on an HCLK edge");
        end
    endtask

    initial begin
        last_hclk_posedge = 0;

        // Cold start with the external button already released must still begin
        // in reset, then perform the complete synchronized qualification.
        #1;
        check_condition(system_reset_n === 1'b0, "cold-start reset is not deterministic LOW");
        check_condition(!$isunknown(system_reset_n), "cold-start reset is X");
        wait_system_release();

        // Arbitrary-phase assertion must not wait for another HCLK edge.
        @(negedge hclk); #3 reset_button_n = 1'b0; #1;
        check_condition(system_reset_n === 1'b0, "asynchronous system assertion failed");

        // A partial release and bounce must restart the full qualification.
        #4 reset_button_n = 1'b1;
        wait (u_system_reset.reset_release_sync === 1'b1);
        repeat (3) begin @(posedge hclk); #1; end
        check_condition(system_reset_n === 1'b0, "system reset released before qualification");
        #3 reset_button_n = 1'b0; #1;
        check_condition(system_reset_n === 1'b0, "bounce failed to retain reset");
        #2 reset_button_n = 1'b1;
        wait_system_release();

        // A short pulse between clock edges must still assert and must require a
        // complete qualification after the pulse ends.
        @(negedge hclk); #2 reset_button_n = 1'b0; #1;
        check_condition(system_reset_n === 1'b0, "short reset pulse was not captured");
        #2 reset_button_n = 1'b1;
        wait_system_release();

        // ADC project logic is inactive until two adc_sys_clk release stages.
        #3 adc_source_reset_n = 1'b1;
        @(posedge adc_clk); #1;
        check_condition(adc_reset_n === 1'b0 && adc_valid === 1'b0,
               "ADC reset released after only one destination edge");
        @(posedge adc_clk); #1;
        check_condition(adc_reset_n === 1'b1 && adc_valid === 1'b1,
               "ADC reset/valid did not release after two destination edges");
        check_condition(adc_channel == 5'd1 && adc_sop && adc_eop,
               "ADC reset channel or packet framing is wrong");
        adc_ready = 1'b1;
        @(posedge adc_clk); #1;
        check_condition(adc_channel == 5'd2, "ADC channel did not advance on ready");
        @(negedge adc_clk); #3 adc_source_reset_n = 1'b0; #1;
        check_condition(adc_reset_n === 1'b0 && adc_valid === 1'b0,
               "ADC local reset did not assert asynchronously during activity");
        check_condition(adc_channel == 5'd1, "ADC channel did not return to channel 1");
        adc_ready = 1'b0;

        // AUX is fail-safe LOW/not-ready throughout reset for both physical
        // levels. It appears as a level after the existing two stages.
        #1;
        check_condition(prdata[3] === 1'b0, "AUX status is ready during reset");
        lora_aux = 1'b1;
        repeat (2) begin @(posedge hclk); #1; end
        check_condition(prdata[3] === 1'b0, "physical AUX HIGH escaped reset containment");
        #3 aux_reset_n = 1'b1;
        @(posedge hclk); #1;
        check_condition(prdata[3] === 1'b0, "AUX bypassed the first synchronizer stage");
        @(posedge hclk); #1;
        check_condition(prdata[3] === 1'b1, "AUX HIGH-ready level did not propagate");
        @(negedge hclk); #3 lora_aux = 1'b0;
        @(posedge hclk); #1;
        check_condition(prdata[3] === 1'b1, "AUX changed before two-stage synchronization");
        @(posedge hclk); #1;
        check_condition(prdata[3] === 1'b0, "AUX LOW/not-ready level did not propagate");
        #3 lora_aux = 1'b1;
        repeat (2) begin @(posedge hclk); #1; end
        check_condition(prdata[3] === 1'b1, "AUX HIGH-ready needs an undocumented delay");
        lora_aux = 1'b0;
        repeat (2) begin @(posedge hclk); #1; end
        check_condition(prdata[3] === 1'b0, "repeated AUX LOW did not propagate");
        lora_aux = 1'b1;
        repeat (2) begin @(posedge hclk); #1; end
        check_condition(prdata[3] === 1'b1, "repeated AUX HIGH did not propagate");
        #3 aux_reset_n = 1'b0; #1;
        check_condition(prdata[3] === 1'b0 && lora_tx === 1'b1,
               "AUX/UART reset state is not fail-safe");

        $display("SUMMARY: PASS P05B system reset, ADC reset, and AUX CDC");
        $finish;
    end
endmodule
