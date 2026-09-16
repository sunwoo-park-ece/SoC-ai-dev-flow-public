`timescale 1ns/1ps
module tb_adc_qsys;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg command_valid = 1'b0;
    reg [4:0] command_channel = 5'd0;
    reg command_sop = 1'b1;
    reg command_eop = 1'b1;
    wire command_ready;
    wire response_valid;
    wire [4:0] response_channel;
    wire [11:0] response_data;
    wire response_sop, response_eop, adc_clk;
    integer accepted_cycle;
    integer response_cycle;
    integer cycle_count = 0;

    always #5 clk = ~clk;
    always @(posedge clk) cycle_count <= cycle_count + 1;

    adc_qsys #(.RESPONSE_LATENCY(3)) dut (
        .clk_clk(clk), .clock_bridge_sys_out_clk_clk(adc_clk),
        .modular_adc_0_command_valid(command_valid),
        .modular_adc_0_command_channel(command_channel),
        .modular_adc_0_command_startofpacket(command_sop),
        .modular_adc_0_command_endofpacket(command_eop),
        .modular_adc_0_command_ready(command_ready),
        .modular_adc_0_response_valid(response_valid),
        .modular_adc_0_response_channel(response_channel),
        .modular_adc_0_response_data(response_data),
        .modular_adc_0_response_startofpacket(response_sop),
        .modular_adc_0_response_endofpacket(response_eop),
        .reset_reset_n(reset_n)
    );

    task send_and_expect(input [4:0] channel, input [11:0] sample);
        begin
            @(negedge clk);
            command_channel = channel;
            command_valid = 1'b1;
            while (!command_ready) @(negedge clk);
            @(posedge clk); #1; accepted_cycle = cycle_count;
            @(negedge clk); command_valid = 1'b0;
            begin : wait_for_response
                do begin
                    @(posedge clk); #1;
                end while (!response_valid);
            end
            response_cycle = cycle_count;
            if ((response_cycle - accepted_cycle) != 3)
                $fatal(1, "ADC latency got %0d", response_cycle - accepted_cycle);
            if (response_channel !== channel || response_data !== sample)
                $fatal(1, "ADC response channel/data mismatch");
            if (!response_sop || !response_eop)
                $fatal(1, "ADC response packet markers");
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        reset_n = 1'b1;
        if (adc_clk !== clk) $fatal(1, "ADC clock bridge");
        send_and_expect(5'd1, 12'h600);
        send_and_expect(5'd2, 12'hA00);
        dut.set_channel_sample(5'd7, 12'h357);
        send_and_expect(5'd7, 12'h357);

        // Reset cancels an accepted command.
        @(negedge clk); command_channel = 5'd1; command_valid = 1'b1;
        @(posedge clk); #1;
        reset_n = 1'b0; command_valid = 1'b0;
        repeat (4) @(posedge clk);
        if (response_valid) $fatal(1, "ADC response survived reset");
        $display("SUMMARY: PASS ADC model");
        $finish;
    end
endmodule
