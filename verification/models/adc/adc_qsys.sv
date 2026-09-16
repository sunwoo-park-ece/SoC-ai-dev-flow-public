// Functional OPEN_SIM replacement for the Intel MAX 10 adc_qsys boundary.
module adc_qsys #(
    parameter integer RESPONSE_LATENCY = 3,
    parameter [11:0] CHANNEL1_SAMPLE = 12'h600,
    parameter [11:0] CHANNEL2_SAMPLE = 12'hA00,
    parameter [11:0] DEFAULT_SAMPLE  = 12'h800
) (
    input  wire        clk_clk,
    output wire        clock_bridge_sys_out_clk_clk,
    input  wire        modular_adc_0_command_valid,
    input  wire [4:0]  modular_adc_0_command_channel,
    input  wire        modular_adc_0_command_startofpacket,
    input  wire        modular_adc_0_command_endofpacket,
    output wire        modular_adc_0_command_ready,
    output reg         modular_adc_0_response_valid,
    output reg  [4:0]  modular_adc_0_response_channel,
    output reg  [11:0] modular_adc_0_response_data,
    output reg         modular_adc_0_response_startofpacket,
    output reg         modular_adc_0_response_endofpacket,
    input  wire        reset_reset_n
);
    reg [11:0] channel_samples [0:31];
    reg [4:0] pending_channel;
    reg [31:0] latency_count;
    reg pending_valid;
    integer i;

    assign clock_bridge_sys_out_clk_clk = clk_clk;
    assign modular_adc_0_command_ready = reset_reset_n && !pending_valid;

    initial begin
        if (RESPONSE_LATENCY < 1)
            $fatal(1, "adc_qsys: RESPONSE_LATENCY must be at least one cycle");
        for (i = 0; i < 32; i = i + 1)
            channel_samples[i] = DEFAULT_SAMPLE;
        channel_samples[1] = CHANNEL1_SAMPLE;
        channel_samples[2] = CHANNEL2_SAMPLE;
    end

    task set_channel_sample;
        input [4:0] channel;
        input [11:0] sample;
        begin
            channel_samples[channel] = sample;
        end
    endtask

    always @(posedge clk_clk or negedge reset_reset_n) begin
        if (!reset_reset_n) begin
            pending_channel <= 5'd0;
            latency_count <= 32'd0;
            pending_valid <= 1'b0;
            modular_adc_0_response_valid <= 1'b0;
            modular_adc_0_response_channel <= 5'd0;
            modular_adc_0_response_data <= 12'd0;
            modular_adc_0_response_startofpacket <= 1'b0;
            modular_adc_0_response_endofpacket <= 1'b0;
        end else begin
            modular_adc_0_response_valid <= 1'b0;
            modular_adc_0_response_startofpacket <= 1'b0;
            modular_adc_0_response_endofpacket <= 1'b0;

            if (pending_valid) begin
                if (latency_count == 32'd1) begin
                    pending_valid <= 1'b0;
                    modular_adc_0_response_valid <= 1'b1;
                    modular_adc_0_response_channel <= pending_channel;
                    modular_adc_0_response_data <= channel_samples[pending_channel];
                    modular_adc_0_response_startofpacket <= 1'b1;
                    modular_adc_0_response_endofpacket <= 1'b1;
                end else begin
                    latency_count <= latency_count - 32'd1;
                end
            end

            if (modular_adc_0_command_valid && modular_adc_0_command_ready) begin
                if (!modular_adc_0_command_startofpacket || !modular_adc_0_command_endofpacket)
                    $error("adc_qsys: command must be a single SOP/EOP beat");
                pending_channel <= modular_adc_0_command_channel;
                latency_count <= RESPONSE_LATENCY;
                pending_valid <= 1'b1;
            end
        end
    end
endmodule
