`timescale 1ns/1ps

module tb_adc_acquisition_engine;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg enable = 1'b0;
    reg command_ready = 1'b0;
    reg response_valid = 1'b0;
    reg [4:0] response_channel = 5'd0;
    reg [11:0] response_data = 12'd0;
    reg response_sop = 1'b1;
    reg response_eop = 1'b1;
    reg frame_ready = 1'b0;

    wire command_valid;
    wire engine_enabled;
    wire [4:0] command_channel;
    wire command_sop, command_eop;
    wire frame_valid;
    wire [31:0] frame_seq;
    wire [5:0] valid_mask;
    wire [71:0] samples_flat;
    wire [3:0] error_event;

    integer accepted_commands = 0;
    integer accepted_frames = 0;

    always #5 clk = ~clk;

    adc_acquisition_engine dut (
        .adc_sys_clk(clk),
        .adc_reset_n(reset_n),
        .enable(enable),
        .engine_enabled(engine_enabled),
        .command_valid(command_valid),
        .command_channel(command_channel),
        .command_startofpacket(command_sop),
        .command_endofpacket(command_eop),
        .command_ready(command_ready),
        .response_valid(response_valid),
        .response_channel(response_channel),
        .response_data(response_data),
        .response_startofpacket(response_sop),
        .response_endofpacket(response_eop),
        .frame_valid(frame_valid),
        .frame_ready(frame_ready),
        .frame_seq(frame_seq),
        .valid_mask(valid_mask),
        .samples_flat(samples_flat),
        .error_event(error_event)
    );

    always @(posedge clk) begin
        if (!reset_n && command_valid)
            $fatal(1, "CHK_RESET_NO_COMMAND: command before local reset release");
        if (command_valid && command_ready)
            accepted_commands <= accepted_commands + 1;
        if (frame_valid && frame_ready)
            accepted_frames <= accepted_frames + 1;
    end

    task expect_command;
        input [4:0] channel;
        input integer stall_cycles;
        integer i;
        reg [4:0] held_channel;
        reg held_sop, held_eop;
        begin
            while (!command_valid) @(negedge clk);
            if (command_channel !== channel || !command_sop || !command_eop)
                $fatal(1, "CHK_COMMAND_SHAPE: expected ch%0d got valid=%b ch%0d SOP/EOP=%b%b",
                       channel, command_valid, command_channel, command_sop, command_eop);
            held_channel = command_channel;
            held_sop = command_sop;
            held_eop = command_eop;
            command_ready = 1'b0;
            for (i = 0; i < stall_cycles; i = i + 1) begin
                @(posedge clk); #1;
                if (!command_valid || command_channel !== held_channel ||
                    command_sop !== held_sop || command_eop !== held_eop)
                    $fatal(1, "CHK_STALLED_COMMAND_STABLE: command changed while not ready");
                @(negedge clk);
            end
            command_ready = 1'b1;
            @(posedge clk); #1;
            command_ready = 1'b0;
        end
    endtask

    task send_response;
        input [4:0] channel;
        input [11:0] data;
        input sop;
        input eop;
        begin
            @(negedge clk);
            response_channel = channel;
            response_data = data;
            response_sop = sop;
            response_eop = eop;
            response_valid = 1'b1;
            @(posedge clk); #1;
            response_valid = 1'b0;
            response_sop = 1'b1;
            response_eop = 1'b1;
        end
    endtask

    task expect_error;
        input [3:0] expected;
        begin
            if (error_event !== expected)
                $fatal(1, "CHK_ERROR_ENCODING: expected %b got %b", expected, error_event);
            if (frame_valid)
                $fatal(1, "CHK_BAD_FRAME_NOT_PUBLISHED: frame_valid asserted after error");
        end
    endtask

    task check_frame;
        input [31:0] seq;
        input [11:0] ch1;
        input [11:0] ch2;
        begin
            if (!frame_valid || frame_seq !== seq || valid_mask !== 6'b000011)
                $fatal(1, "CHK_COMPLETE_FRAME: valid/seq/mask got %b/%0d/%b",
                       frame_valid, frame_seq, valid_mask);
            if (samples_flat[11:0] !== ch1 || samples_flat[23:12] !== ch2 ||
                samples_flat[71:24] !== 48'd0)
                $fatal(1, "CHK_FRAME_PAYLOAD: CH1=%h CH2=%h upper=%h",
                       samples_flat[11:0], samples_flat[23:12], samples_flat[71:24]);
        end
    endtask

    integer i;
    reg [31:0] held_seq;
    reg [5:0] held_mask;
    reg [71:0] held_samples;

    initial begin
        repeat (2) @(posedge clk);
        if (command_valid) $fatal(1, "CHK_RESET_NO_COMMAND: reset asserted");
        if (engine_enabled) $fatal(1, "CHK_ENGINE_ACK_RESET: reset acknowledged enabled");
        reset_n = 1'b1;
        repeat (2) @(posedge clk);
        if (command_valid) $fatal(1, "CHK_DISABLED_QUIET: command while disabled");
        if (engine_enabled) $fatal(1, "CHK_ENGINE_ACK_DISABLED: disabled acknowledged enabled");

        // Nominal CH1 -> CH2 frame; command backpressure must preserve payload.
        @(negedge clk); enable = 1'b1;
        expect_command(5'd1, 3);
        if (!engine_enabled) $fatal(1, "CHK_ENGINE_ACK_ACTIVE: active engine not acknowledged");
        send_response(5'd1, 12'h123, 1'b1, 1'b1);
        expect_command(5'd2, 2);
        send_response(5'd2, 12'habc, 1'b1, 1'b1);
        #1; check_frame(32'd1, 12'h123, 12'habc);

        // Downstream backpressure holds the complete frame and blocks rescans.
        held_seq = frame_seq;
        held_mask = valid_mask;
        held_samples = samples_flat;
        repeat (4) begin
            @(posedge clk); #1;
            if (!frame_valid || frame_seq !== held_seq || valid_mask !== held_mask ||
                samples_flat !== held_samples || command_valid)
                $fatal(1, "CHK_FRAME_HOLD_BACKPRESSURE: held frame changed or scan restarted");
        end
        @(negedge clk); frame_ready = 1'b1;
        @(posedge clk); #1; frame_ready = 1'b0;

        // Consecutive accepted frame increments sequence exactly once.
        expect_command(5'd1, 0);
        send_response(5'd1, 12'h456, 1'b1, 1'b1);
        expect_command(5'd2, 0);
        send_response(5'd2, 12'h789, 1'b1, 1'b1);
        #1; check_frame(32'd2, 12'h456, 12'h789);
        @(negedge clk); frame_ready = 1'b1;
        @(posedge clk); #1; frame_ready = 1'b0;

        // Wrong/unexpected channel and out-of-order CH2 while CH1 is expected.
        expect_command(5'd1, 0);
        send_response(5'd6, 12'h111, 1'b1, 1'b1);
        #1; expect_error(4'b0001);
        expect_command(5'd1, 0);
        send_response(5'd2, 12'h222, 1'b1, 1'b1);
        #1; expect_error(4'b0100);

        // A repeated CH1 in the CH2 slot is a duplicate, not a new frame.
        expect_command(5'd1, 0);
        send_response(5'd1, 12'h333, 1'b1, 1'b1);
        expect_command(5'd2, 0);
        send_response(5'd1, 12'h444, 1'b1, 1'b1);
        #1; expect_error(4'b0010);

        // Each half of the single-beat SOP/EOP contract is checked.
        expect_command(5'd1, 0);
        send_response(5'd1, 12'h555, 1'b0, 1'b1);
        #1; expect_error(4'b1000);
        expect_command(5'd1, 0);
        send_response(5'd1, 12'h666, 1'b1, 1'b1);
        expect_command(5'd2, 0);
        send_response(5'd2, 12'h777, 1'b1, 1'b0);
        #1; expect_error(4'b1000);

        // Disable after CH1 is stored but before the CH2 command is accepted.
        expect_command(5'd1, 0);
        send_response(5'd1, 12'h7a1, 1'b1, 1'b1);
        if (!command_valid || command_channel !== 5'd2)
            $fatal(1, "CHK_PARTIAL_FRAME_STATE: CH2 was not next after good CH1");
        @(negedge clk); enable = 1'b0;
        #1;
        if (command_valid)
            $fatal(1, "CHK_DISABLE_SUPPRESSES_UNACCEPTED_COMMAND: CH2 remained valid");
        repeat (2) @(posedge clk);
        #1;
        if (frame_valid || frame_seq !== 32'd2)
            $fatal(1, "CHK_DISABLE_PARTIAL_DISCARD: partial frame changed publication state");
        if (engine_enabled) $fatal(1, "CHK_ENGINE_ACK_QUIESCENT: engine remained active after partial discard");

        // Disable after an accepted CH1 command drains its response and drops
        // the partial frame; re-enable restarts at CH1.
        @(negedge clk); enable = 1'b1;
        expect_command(5'd1, 0);
        @(negedge clk); enable = 1'b0;
        repeat (2) begin
            @(posedge clk); #1;
            if (command_valid || frame_valid)
                $fatal(1, "CHK_DISABLE_PARTIAL: issue/publication continued while disabled");
            if (!engine_enabled)
                $fatal(1, "CHK_ENGINE_ACK_DRAIN: early disabled acknowledgement before accepted response");
        end
        send_response(5'd1, 12'h888, 1'b1, 1'b1);
        repeat (2) @(posedge clk);
        if (frame_valid || command_valid || frame_seq !== 32'd2)
            $fatal(1, "CHK_DISABLE_DRAIN_DISCARD: disabled partial frame escaped");
        if (engine_enabled) $fatal(1, "CHK_ENGINE_ACK_DRAIN_DONE: drain did not quiesce");
        @(negedge clk); enable = 1'b1;
        expect_command(5'd1, 1);
        send_response(5'd1, 12'h999, 1'b1, 1'b1);
        expect_command(5'd2, 1);
        send_response(5'd2, 12'haaa, 1'b1, 1'b1);
        #1; check_frame(32'd3, 12'h999, 12'haaa);

        // Reset clears the engine and sequence, with no command before re-enable.
        @(negedge clk); reset_n = 1'b0; enable = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (command_valid || frame_valid || frame_seq !== 32'd0 || valid_mask !== 6'd0)
            $fatal(1, "CHK_RESET_CLEARS_ACQUISITION: reset state mismatch");
        if (engine_enabled) $fatal(1, "CHK_ENGINE_ACK_RESET: reset left acknowledgement high");
        reset_n = 1'b1;
        repeat (2) @(posedge clk);
        if (command_valid) $fatal(1, "CHK_RESET_DISABLED: command before enable");

        if (accepted_frames != 2)
            $fatal(1, "CHK_FRAME_HANDSHAKES: expected 2 accepted frames, got %0d", accepted_frames);
        if (accepted_commands < 14)
            $fatal(1, "CHK_COMMAND_ACTIVITY: expected directed command traffic, got %0d", accepted_commands);

        $display("PASS CHK_RESET_NO_COMMAND CHK_DISABLED_QUIET CHK_COMMAND_SHAPE");
        $display("PASS CHK_STALLED_COMMAND_STABLE CHK_COMPLETE_FRAME CHK_FRAME_PAYLOAD");
        $display("PASS CHK_FRAME_HOLD_BACKPRESSURE CHK_BAD_FRAME_NOT_PUBLISHED");
        $display("PASS CHK_ERROR_ENCODING CHK_DISABLE_PARTIAL CHK_DISABLE_DRAIN_DISCARD");
        $display("PASS CHK_DISABLE_SUPPRESSES_UNACCEPTED_COMMAND CHK_DISABLE_PARTIAL_DISCARD");
        $display("PASS CHK_RESET_CLEARS_ACQUISITION accepted_commands=%0d accepted_frames=%0d",
                 accepted_commands, accepted_frames);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "CHK_TEST_TIMEOUT");
    end
endmodule
