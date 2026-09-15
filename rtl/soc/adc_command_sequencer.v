// Project-owned command source for the private ADC/Qsys subsystem.
// All state belongs to adc_sys_clk and is held inactive until its local reset
// synchronizer has released.
module adc_command_sequencer (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       command_ready,
    output wire       command_valid,
    output reg  [4:0] command_channel,
    output wire       command_startofpacket,
    output wire       command_endofpacket
);
    assign command_valid         = reset_n;
    assign command_startofpacket = 1'b1;
    assign command_endofpacket   = 1'b1;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            command_channel <= 5'd1;
        else if (command_ready)
            command_channel <= (command_channel == 5'd1) ? 5'd2 : 5'd1;
    end
endmodule
