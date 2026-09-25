`timescale 1ns/1ps

module tb_adc_frame_cdc;
    parameter integer ADC_HALF = 20;
    parameter integer PCLK_HALF = 10;
    parameter integer PCLK_PHASE = 3;
    reg adc_clk = 0, pclk = 0;
    initial forever #(ADC_HALF) adc_clk = ~adc_clk;
    initial begin #(PCLK_PHASE); forever #(PCLK_HALF) pclk = ~pclk; end

    reg adc_reset_n = 0, pclk_reset_n = 0, enable_req = 0;
    reg command_ready = 0, response_valid = 0;
    reg [4:0] response_channel = 0;
    reg [11:0] response_data = 0;
    reg response_sop = 1, response_eop = 1;
    wire command_valid, command_sop, command_eop;
    wire [4:0] command_channel;
    wire engine_enable, engine_enabled, engine_enabled_pclk;
    wire frame_valid, frame_ready, mailbox_busy, frame_pulse_pclk;
    wire [31:0] frame_seq, frame_seq_pclk;
    wire [5:0] valid_mask, valid_mask_pclk;
    wire [71:0] samples_flat, samples_flat_pclk;
    wire [3:0] error_event;
    integer pulses = 0, expected_pulses = 0;
    reg [31:0] expected_seq = 0;
    reg [11:0] expected_ch1 = 0, expected_ch2 = 0;
    reg [109:0] held_payload;
    reg held_req;

    adc_acquisition_engine engine (
        .adc_sys_clk(adc_clk), .adc_reset_n(adc_reset_n), .enable(engine_enable),
        .engine_enabled(engine_enabled), .command_valid(command_valid),
        .command_channel(command_channel), .command_startofpacket(command_sop),
        .command_endofpacket(command_eop), .command_ready(command_ready),
        .response_valid(response_valid), .response_channel(response_channel),
        .response_data(response_data), .response_startofpacket(response_sop),
        .response_endofpacket(response_eop), .frame_valid(frame_valid),
        .frame_ready(frame_ready), .frame_seq(frame_seq), .valid_mask(valid_mask),
        .samples_flat(samples_flat), .error_event(error_event)
    );
    adc_frame_mailbox_cdc cdc (
        .pclk(pclk), .pclk_reset_n(pclk_reset_n), .enable_req(enable_req),
        .engine_enabled_pclk(engine_enabled_pclk), .frame_pulse_pclk(frame_pulse_pclk),
        .frame_seq_pclk(frame_seq_pclk), .valid_mask_pclk(valid_mask_pclk),
        .samples_flat_pclk(samples_flat_pclk), .adc_sys_clk(adc_clk),
        .adc_reset_n(adc_reset_n), .engine_enable(engine_enable),
        .engine_enabled(engine_enabled), .frame_valid(frame_valid),
        .frame_ready(frame_ready), .frame_seq(frame_seq),
        .valid_mask(valid_mask), .samples_flat(samples_flat),
        .mailbox_busy(mailbox_busy)
    );

    always @(posedge pclk) begin
        #1;
        if (frame_pulse_pclk) begin
            if (!engine_enabled_pclk && !enable_req)
                $fatal(1, "CHK_NO_LATE_FRAME_AFTER_DISABLED_ACK");
            pulses = pulses + 1;
            if (pulses > expected_pulses)
                $fatal(1, "CHK_NO_EXTRA_PULSE: unexpected destination publication");
            if (frame_seq_pclk !== expected_seq || valid_mask_pclk !== 6'b000011 ||
                samples_flat_pclk !== {48'd0, expected_ch2, expected_ch1})
                $fatal(1, "CHK_COHERENT_PAYLOAD: seq=%0d mask=%b samples=%h expected %0d/%h/%h",
                       frame_seq_pclk, valid_mask_pclk, samples_flat_pclk,
                       expected_seq, expected_ch1, expected_ch2);
        end
        if (!pclk_reset_n && (frame_pulse_pclk || engine_enabled_pclk))
            $fatal(1, "CHK_RESET_DEST_QUIET");
    end

    always @(posedge adc_clk) begin
        #1;
        if (!engine_enable && command_valid)
            $fatal(1, "CHK_NO_COMMAND_AFTER_DISABLE_RECOGNITION");
        if (error_event != 0)
            $fatal(1, "CHK_NO_UNEXPECTED_SOURCE_ERROR");
        if (cdc.source_state == 2'd1 && (frame_ready || command_valid))
            $fatal(1, "CHK_ACK_SERIALIZATION: scan advanced while ACK pending");
        if (!adc_reset_n && (command_valid || engine_enabled || frame_valid))
            $fatal(1, "CHK_RESET_SOURCE_QUIET");
        if (mailbox_busy && !frame_ready) begin
            if (held_req && cdc.source_payload !== held_payload)
                $fatal(1, "CHK_BUSY_PAYLOAD_STABLE");
            held_payload = cdc.source_payload;
            held_req = 1;
        end else held_req = 0;
    end

    task wait_enabled;
        begin
            wait (engine_enabled_pclk === 1'b1);
            if (!engine_enabled || !engine_enable)
                $fatal(1, "CHK_ENABLED_RETURN_NOT_ECHO");
        end
    endtask
    task expect_command;
        input [4:0] ch;
        begin
            wait (command_valid === 1'b1);
            if (command_channel !== ch || !command_sop || !command_eop)
                $fatal(1, "CHK_COMMAND_ORDER: expected %0d got %0d", ch, command_channel);
            @(negedge adc_clk); command_ready = 1;
            @(posedge adc_clk); #2;
            command_ready = 0;
        end
    endtask
    task send_response;
        input [4:0] ch;
        input [11:0] value;
        begin
            @(negedge adc_clk);
            response_channel = ch; response_data = value; response_valid = 1;
            @(posedge adc_clk); #2;
            response_valid = 0;
        end
    endtask
    task make_frame;
        input [11:0] ch1, ch2;
        input [31:0] seq;
        begin
            expected_pulses = expected_pulses + 1;
            expected_seq = seq; expected_ch1 = ch1; expected_ch2 = ch2;
            $display("make_frame %0d command1 t=%0t state=%0d", seq, $time, engine.state);
            expect_command(1); send_response(1, ch1);
            $display("make_frame %0d command2 t=%0t state=%0d", seq, $time, engine.state);
            expect_command(2); send_response(2, ch2);
            $display("make_frame %0d busy t=%0t state=%0d", seq, $time, engine.state);
            wait (mailbox_busy);
            if (frame_ready || command_valid)
                $fatal(1, "CHK_ACK_SERIALIZATION: engine advanced before ACK");
            wait (pulses == expected_pulses);
            wait (!mailbox_busy);
            repeat (3) @(posedge pclk);
            if (pulses != expected_pulses)
                $fatal(1, "CHK_EXACTLY_ONE_PULSE");
        end
    endtask
    task reset_both;
        begin
            @(negedge adc_clk);
            adc_reset_n = 0; pclk_reset_n = 0; enable_req = 0;
            repeat (4) @(posedge adc_clk);
            @(negedge adc_clk);
            adc_reset_n = 1; pclk_reset_n = 1;
            repeat (6) @(posedge pclk);
            if (frame_pulse_pclk || engine_enabled_pclk || command_valid)
                $fatal(1, "CHK_NO_PHANTOM_AFTER_RESET");
        end
    endtask
    task reset_source_only;
        begin
            @(negedge adc_clk);
            adc_reset_n = 0; enable_req = 0;
            repeat (4) @(posedge adc_clk);
            @(negedge adc_clk); adc_reset_n = 1;
            repeat (6) @(posedge pclk);
            if (frame_pulse_pclk || engine_enabled_pclk || command_valid)
                $fatal(1, "CHK_SOURCE_RESET_NO_PHANTOM");
        end
    endtask

    initial begin
        held_req = 0;
        repeat (4) @(posedge adc_clk);
        reset_both;
        // Two flip-flop request path: enable cannot acknowledge instantly.
        @(negedge pclk); enable_req = 1;
        #1;
        if (engine_enable || engine_enabled_pclk)
            $fatal(1, "CHK_ENABLE_NOT_ASYNC_ECHO");
        wait_enabled;
        $display("stage first frame t=%0t", $time);
        make_frame(12'h123, 12'habc, 1);
        $display("stage second frame t=%0t", $time);
        make_frame(12'h456, 12'h789, 2);
        $display("stage drain t=%0t", $time);

        // Accepted CH1 transaction must drain before acknowledgement falls.
        expect_command(1);
        @(negedge pclk); enable_req = 0;
        wait (!engine_enable);
        repeat (3) @(posedge adc_clk);
        if (!engine_enabled || !engine_enabled_pclk || command_valid)
            $fatal(1, "CHK_DRAIN_ACK_EARLY");
        send_response(1, 12'hddd);
        wait (!engine_enabled_pclk);
        $display("stage reenable t=%0t", $time);
        repeat (4) @(posedge pclk);
        if (pulses != 2) $fatal(1, "CHK_DISABLE_PARTIAL_NO_FRAME");

        @(negedge pclk); enable_req = 1;
        wait_enabled;
        // Disable after a complete frame exists, before mailbox ACK returns.
        expected_pulses = 3; expected_seq = 3;
        expected_ch1 = 12'h111; expected_ch2 = 12'h222;
        expect_command(1); send_response(1, 12'h111);
        expect_command(2); send_response(2, 12'h222);
        wait (mailbox_busy);
        @(negedge pclk); enable_req = 0;
        wait (!engine_enable);
        if (!engine_enabled_pclk)
            $fatal(1, "CHK_MAILBOX_ACK_EARLY");
        wait (pulses == 3);
        $display("stage disable ack t=%0t", $time);
        wait (!engine_enabled_pclk);
        if (mailbox_busy || command_valid)
            $fatal(1, "CHK_DISABLE_QUIESCENCE");
        repeat (5) @(posedge pclk);
        if (pulses != 3) $fatal(1, "CHK_NO_POST_DISABLE_FRAME");

        @(negedge pclk); enable_req = 1;
        wait_enabled;
        make_frame(12'hace, 12'hbdf, 4);

        // Reset while source mailbox holds a publication; no old toggle may
        // produce a post-reset destination pulse.
        expect_command(1); send_response(1, 12'h333);
        expect_command(2); send_response(2, 12'h444);
        wait (mailbox_busy);
        $display("stage reset busy t=%0t", $time);
        reset_source_only;
        if (pulses != 4) $fatal(1, "CHK_RESET_ABORTS_MAILBOX");

        // System/destination reset around the next REQ detection edge.
        @(negedge pclk); enable_req = 1;
        wait_enabled;
        expect_command(1); send_response(1, 12'h555);
        expect_command(2); send_response(2, 12'h666);
        wait (mailbox_busy);
        reset_both;
        if (pulses != 4) $fatal(1, "CHK_SYSTEM_RESET_ABORTS_MAILBOX");

        // Reset with a vendor transaction outstanding also drops its partial.
        @(negedge pclk); enable_req = 1;
        wait_enabled;
        expect_command(1);
        reset_both;
        if (pulses != 4 || frame_valid)
            $fatal(1, "CHK_RESET_ABORTS_PARTIAL");
        $display("PASS B2 CDC ADC_HALF=%0d PCLK_HALF=%0d PHASE=%0d pulses=%0d",
                 ADC_HALF, PCLK_HALF, PCLK_PHASE, pulses);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "CHK_TIMEOUT");
    end
endmodule
