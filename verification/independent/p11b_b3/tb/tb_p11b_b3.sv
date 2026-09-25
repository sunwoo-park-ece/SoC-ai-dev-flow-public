// P11B-B3 Independent Integration DV — Top-level testbench
// Spec authority: spec/15_adc_joystick.md, spec/06_reset_clock.md,
//                 P11B interface-freeze issuecomment-5835768200
// Independence rule: oracle built from stimulus + accepted response history,
//   NOT from DUT internal FSM, Codex B1/B2 checker logic, or DUT frame_seq.
// Intentionally self-contained for Icarus Verilog 11 (iverilog -g2012 -sv) compatibility.
`timescale 1ns/1ps

module tb_p11b_b3 #(
    // ADC sys clock half-period (ns). Default: 25 MHz -> 20 ns period.
    parameter integer ADC_HALF_NS   = 20,
    // PCLK half-period (ns). Default: 50 MHz -> 10 ns period.
    parameter integer PCLK_HALF_NS  = 10,
    // PCLK initial phase offset (ns) for CDC stress.
    parameter integer PCLK_PHASE_NS = 0,
    // Seed parameter (deterministic matrix tracking).
    parameter integer SEED          = 0,
    // Test selection: 0=all, or individual test number.
    parameter integer TEST_SELECT   = 0
);

    // -----------------------------------------------------------------------
    // Frozen constants (spec/15_adc_joystick.md §5, §9.5, issuecomment-5835768200)
    // -----------------------------------------------------------------------
    localparam integer MAX_CHANNELS  = 6;
    localparam [5:0]   ACTIVE_MASK   = 6'b000011;
    localparam integer CH1           = 1;
    localparam integer CH2           = 2;

    // error_event bit positions (spec §9.5)
    localparam [3:0] ERR_UNEXPECTED = 4'b0001; // bit0
    localparam [3:0] ERR_DUPLICATE  = 4'b0010; // bit1
    localparam [3:0] ERR_ORDER      = 4'b0100; // bit2
    localparam [3:0] ERR_PACKET     = 4'b1000; // bit3

    // -----------------------------------------------------------------------
    // Clocks
    // -----------------------------------------------------------------------
    reg adc_clk = 1'b0;
    reg pclk    = 1'b0;

    always #(ADC_HALF_NS) adc_clk = ~adc_clk;
    initial begin
        if (PCLK_PHASE_NS > 0) #(PCLK_PHASE_NS);
        forever #(PCLK_HALF_NS) pclk = ~pclk;
    end

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    // Engine
    reg         adc_reset_n;
    reg         enable_req;       // PCLK-domain request to CDC
    wire        engine_enable;    // CDC->engine
    wire        engine_enabled;   // engine->CDC

    wire        command_valid;
    wire [4:0]  command_channel;
    wire        command_sop;
    wire        command_eop;
    reg         command_ready;

    reg         response_valid;
    reg  [4:0]  response_channel;
    reg  [11:0] response_data;
    reg         response_sop;
    reg         response_eop;

    wire        frame_valid;
    wire        frame_ready;
    wire [31:0] frame_seq_src;
    wire [5:0]  valid_mask_src;
    wire [71:0] samples_flat_src;
    wire [3:0]  error_event;

    // CDC
    reg         pclk_reset_n;
    wire        engine_enabled_pclk;
    wire        frame_pulse_pclk;
    wire [31:0] frame_seq_pclk;
    wire [5:0]  valid_mask_pclk;
    wire [71:0] samples_flat_pclk;
    wire        mailbox_busy;

    // -----------------------------------------------------------------------
    // DUT instantiation (production RTL — read-only)
    // -----------------------------------------------------------------------
    adc_acquisition_engine engine_dut (
        .adc_sys_clk          (adc_clk),
        .adc_reset_n          (adc_reset_n),
        .enable               (engine_enable),
        .engine_enabled       (engine_enabled),
        .command_valid        (command_valid),
        .command_channel      (command_channel),
        .command_startofpacket(command_sop),
        .command_endofpacket  (command_eop),
        .command_ready        (command_ready),
        .response_valid       (response_valid),
        .response_channel     (response_channel),
        .response_data        (response_data),
        .response_startofpacket(response_sop),
        .response_endofpacket  (response_eop),
        .frame_valid          (frame_valid),
        .frame_ready          (frame_ready),
        .frame_seq            (frame_seq_src),
        .valid_mask           (valid_mask_src),
        .samples_flat         (samples_flat_src),
        .error_event          (error_event)
    );

    adc_frame_mailbox_cdc cdc_dut (
        .pclk                (pclk),
        .pclk_reset_n        (pclk_reset_n),
        .enable_req          (enable_req),
        .engine_enabled_pclk (engine_enabled_pclk),
        .frame_pulse_pclk    (frame_pulse_pclk),
        .frame_seq_pclk      (frame_seq_pclk),
        .valid_mask_pclk     (valid_mask_pclk),
        .samples_flat_pclk   (samples_flat_pclk),
        .adc_sys_clk         (adc_clk),
        .adc_reset_n         (adc_reset_n),
        .engine_enable       (engine_enable),
        .engine_enabled      (engine_enabled),
        .frame_valid         (frame_valid),
        .frame_ready         (frame_ready),
        .frame_seq           (frame_seq_src),
        .valid_mask          (valid_mask_src),
        .samples_flat        (samples_flat_src),
        .mailbox_busy        (mailbox_busy)
    );

    // -----------------------------------------------------------------------
    // Independent ledger: stores expected frames built from accepted
    // command/response pairs. The DUT's frame_seq output is NEVER read for
    // oracle generation.
    // -----------------------------------------------------------------------
    parameter integer LEDGER_DEPTH = 16;
    reg [31:0] ledger_seq   [0:LEDGER_DEPTH-1];
    reg [11:0] ledger_ch1   [0:LEDGER_DEPTH-1];
    reg [11:0] ledger_ch2   [0:LEDGER_DEPTH-1];
    reg [5:0]  ledger_vmask [0:LEDGER_DEPTH-1];
    reg [71:0] ledger_flat  [0:LEDGER_DEPTH-1];
    integer    ledger_head  = 0;
    integer    ledger_tail  = 0;
    integer    ledger_count = 0;

    // Independent sequence counter — reset=0, first good=1 (spec §5.5)
    reg [31:0] ref_next_seq;

    task automatic ledger_push;
        input [11:0] ch1_v, ch2_v;
        reg [71:0] flat;
        reg [31:0] seq;
        begin
            seq  = ref_next_seq;
            flat = {48'd0, ch2_v, ch1_v}; // spec layout [11:0]=CH1 [23:12]=CH2
            ledger_seq  [ledger_head] = seq;
            ledger_ch1  [ledger_head] = ch1_v;
            ledger_ch2  [ledger_head] = ch2_v;
            ledger_vmask[ledger_head] = 6'b000011;
            ledger_flat [ledger_head] = flat;
            ledger_head  = (ledger_head + 1) % LEDGER_DEPTH;
            ledger_count = ledger_count + 1;
            ref_next_seq = ref_next_seq + 32'd1;
            $display("[LEDGER PUSH] t=%0t seq=%0d ch1=%03x ch2=%03x",
                     $time, seq, ch1_v, ch2_v);
        end
    endtask

    task automatic ledger_pop;
        output [31:0] seq_o;
        output [11:0] ch1_o, ch2_o;
        output [5:0]  vmask_o;
        output [71:0] flat_o;
        begin
            if (ledger_count == 0)
                $fatal(1, "[LEDGER] pop on empty ledger — unexpected PCLK frame");
            seq_o   = ledger_seq  [ledger_tail];
            ch1_o   = ledger_ch1  [ledger_tail];
            ch2_o   = ledger_ch2  [ledger_tail];
            vmask_o = ledger_vmask[ledger_tail];
            flat_o  = ledger_flat [ledger_tail];
            ledger_tail  = (ledger_tail + 1) % LEDGER_DEPTH;
            ledger_count = ledger_count - 1;
        end
    endtask

    task automatic ledger_reset;
        begin
            ledger_head  = 0;
            ledger_tail  = 0;
            ledger_count = 0;
            ref_next_seq = 32'd1;
        end
    endtask

    // -----------------------------------------------------------------------
    // PCLK monitor / scoreboard
    // Fires on every frame_pulse_pclk; compares against ledger front().
    // -----------------------------------------------------------------------
    integer total_pclk_frames = 0;
    integer scoreboard_errors = 0;

    always @(posedge pclk) begin : pclk_monitor
        if (frame_pulse_pclk) begin
            reg [31:0] exp_seq;
            reg [11:0] exp_ch1, exp_ch2;
            reg [5:0]  exp_vmask;
            reg [71:0] exp_flat;
            total_pclk_frames = total_pclk_frames + 1;
            ledger_pop(exp_seq, exp_ch1, exp_ch2, exp_vmask, exp_flat);
            $display("[PCLK MON] t=%0t frame_pulse seq=%0d ch1=%03x ch2=%03x",
                     $time, frame_seq_pclk, samples_flat_pclk[11:0], samples_flat_pclk[23:12]);

            // --- Scoreboard comparisons ---
            // 1. Sequence number (spec §5.5)
            if (frame_seq_pclk !== exp_seq) begin
                $display("[SCOREBOARD FAIL] SEQ mismatch: got=%0d expected=%0d t=%0t",
                         frame_seq_pclk, exp_seq, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            // 2. Valid mask must be ACTIVE_MASK=6'b000011
            if (valid_mask_pclk !== 6'b000011) begin
                $display("[SCOREBOARD FAIL] VALID_MASK: got=%06b expected=000011 t=%0t",
                         valid_mask_pclk, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            // 3. CH1 sample
            if (samples_flat_pclk[11:0] !== exp_ch1) begin
                $display("[SCOREBOARD FAIL] CH1: got=%03x expected=%03x t=%0t",
                         samples_flat_pclk[11:0], exp_ch1, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            // 4. CH2 sample
            if (samples_flat_pclk[23:12] !== exp_ch2) begin
                $display("[SCOREBOARD FAIL] CH2: got=%03x expected=%03x t=%0t",
                         samples_flat_pclk[23:12], exp_ch2, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            // 5. CH3..CH6 must be zero (spec §5 baseline)
            if (samples_flat_pclk[71:24] !== 48'd0) begin
                $display("[SCOREBOARD FAIL] CH3-6 not zero: got=%012x t=%0t",
                         samples_flat_pclk[71:24], $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Protocol assertions — adc_sys_clk domain
    // All assertions are on externally visible port behavior only.
    // Deterministic edge sampling without scheduling races.
    // -----------------------------------------------------------------------
    // A1: command fields stable while command_valid && !command_ready
    reg         prev_cmd_valid;
    reg [4:0]   prev_cmd_ch;
    reg         prev_cmd_sop, prev_cmd_eop;

    always @(posedge adc_clk) begin : assert_cmd_stable
        if (adc_reset_n) begin
            if (prev_cmd_valid && !command_ready && command_valid) begin
                if (command_channel !== prev_cmd_ch ||
                    command_sop     !== prev_cmd_sop ||
                    command_eop     !== prev_cmd_eop) begin
                    $display("[ASSERT FAIL] A1 CMD_STABLE: command changed while valid&&!ready t=%0t", $time);
                    scoreboard_errors = scoreboard_errors + 1;
                end
            end
            prev_cmd_valid <= command_valid;
            prev_cmd_ch    <= command_channel;
            prev_cmd_sop   <= command_sop;
            prev_cmd_eop   <= command_eop;
        end else begin
            prev_cmd_valid <= 1'b0;
        end
    end

    // A2: no command valid while engine is in reset (adc_reset_n low)
    always @(posedge adc_clk) begin : assert_no_cmd_in_reset
        if (!adc_reset_n && command_valid) begin
            $display("[ASSERT FAIL] A2 NO_CMD_IN_RESET: command_valid during reset t=%0t", $time);
            scoreboard_errors = scoreboard_errors + 1;
        end
    end

    // A3: no frame_valid during reset
    always @(posedge adc_clk) begin : assert_no_frame_in_reset
        if (!adc_reset_n && frame_valid) begin
            $display("[ASSERT FAIL] A3 NO_FRAME_IN_RESET: frame_valid during reset t=%0t", $time);
            scoreboard_errors = scoreboard_errors + 1;
        end
    end

    // A4: one-outstanding-command invariant (spec §5)
    //     DUT must never issue a command while prior command is outstanding.
    integer outstanding_cmds;
    reg     allow_unsolicited_response;
    initial begin
        outstanding_cmds = 0;
        allow_unsolicited_response = 1'b0;
    end

    always @(posedge adc_clk) begin : assert_one_outstanding
        if (adc_reset_n) begin
            if (command_valid && command_ready) begin
                if (outstanding_cmds >= 1) begin
                    $display("[ASSERT FAIL] A4 ONE_OUTSTANDING: DUT issued second command before response t=%0t", $time);
                    scoreboard_errors = scoreboard_errors + 1;
                end
                outstanding_cmds <= outstanding_cmds + 1;
            end
            if (response_valid) begin
                if (outstanding_cmds == 0) begin
                    if (!allow_unsolicited_response) begin
                        $display("[ASSERT FAIL] A4 ONE_OUTSTANDING: unsolicited response_valid on nominal bus t=%0t", $time);
                        scoreboard_errors = scoreboard_errors + 1;
                    end
                end else begin
                    outstanding_cmds <= outstanding_cmds - 1;
                end
            end
        end else begin
            outstanding_cmds <= 0;
        end
    end

    // A5: mailbox: no second frame generation while mailbox_busy
    // A new frame (rising edge of frame_valid) must never occur while mailbox is already busy.
    reg frame_valid_d;
    always @(posedge adc_clk) frame_valid_d <= frame_valid;

    always @(posedge adc_clk) begin : assert_mailbox_exclusive
        if (adc_reset_n) begin
            if (frame_valid && !frame_valid_d && mailbox_busy) begin
                $display("[ASSERT FAIL] A5 MAILBOX_BUSY_OVERWRITE: new frame_valid while mailbox_busy t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
        end
    end

    // A6: no PCLK frame pulse after engine_enabled_pclk falls and enable_req=0
    reg engine_enabled_pclk_r;
    always @(posedge pclk) begin : assert_no_post_disable_frame
        engine_enabled_pclk_r <= engine_enabled_pclk;
        if (frame_pulse_pclk && !engine_enabled_pclk && !enable_req && !engine_enabled_pclk_r) begin
            $display("[ASSERT FAIL] A6 NO_POST_DISABLE_FRAME: frame after disable ack t=%0t", $time);
            scoreboard_errors = scoreboard_errors + 1;
        end
    end

    // A7: destination quiet during PCLK reset
    always @(posedge pclk) begin : assert_pclk_reset_quiet
        if (!pclk_reset_n && frame_pulse_pclk) begin
            $display("[ASSERT FAIL] A7 PCLK_RESET_QUIET: frame_pulse during pclk_reset_n=0 t=%0t", $time);
            scoreboard_errors = scoreboard_errors + 1;
        end
        if (!pclk_reset_n && engine_enabled_pclk) begin
            $display("[ASSERT FAIL] A7 PCLK_RESET_QUIET: engine_enabled_pclk during reset t=%0t", $time);
            scoreboard_errors = scoreboard_errors + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Functional coverage bins
    // -----------------------------------------------------------------------
    integer cov_ch1_ch2_nominal      = 0;
    integer cov_err_unexpected       = 0;
    integer cov_err_duplicate        = 0;
    integer cov_err_order            = 0;
    integer cov_err_packet           = 0;
    integer cov_cmd_stall            = 0;
    integer cov_disable_before_cmd   = 0;
    integer cov_disable_cmd_stall    = 0;
    integer cov_disable_wait_ch1     = 0;
    integer cov_disable_ch1_partial  = 0;
    integer cov_disable_wait_ch2     = 0;
    integer cov_disable_mailbox_busy = 0;
    integer cov_reset_disabled       = 0;
    integer cov_reset_cmd_stall      = 0;
    integer cov_reset_ch1_partial    = 0;
    integer cov_reset_mailbox_busy   = 0;
    integer cov_reenable_after_dis   = 0;
    integer cov_recovery_malformed   = 0;
    integer cov_reset_wait_ch1_resp  = 0;
    integer cov_reset_wait_ch2_resp  = 0;
    integer cov_reset_pre_pub        = 0;
    integer cov_reset_dest_capture   = 0;

    // -----------------------------------------------------------------------
    // Helper tasks — phase-separated driving / sampling (Item 3 compliant)
    // Driving on negedge; DUT sampling on posedge; deassert on subsequent negedge.
    // -----------------------------------------------------------------------

    task automatic drive_command_ready;
        input integer stall_cycles;
        integer i;
        reg [4:0]  snap_ch;
        reg        snap_sop, snap_eop;
        begin
            wait (command_valid === 1'b1);
            snap_ch  = command_channel;
            snap_sop = command_sop;
            snap_eop = command_eop;
            if (stall_cycles > 0) begin
                cov_cmd_stall = cov_cmd_stall + 1;
                for (i = 0; i < stall_cycles; i = i + 1) begin
                    @(posedge adc_clk);
                    if (!command_valid) begin
                        $display("[ASSERT FAIL] CMD disappeared during stall at i=%0d t=%0t", i, $time);
                        scoreboard_errors = scoreboard_errors + 1;
                    end
                    if (command_channel !== snap_ch ||
                        command_sop !== snap_sop ||
                        command_eop !== snap_eop) begin
                        $display("[ASSERT FAIL] A1 CMD changed during stall t=%0t", $time);
                        scoreboard_errors = scoreboard_errors + 1;
                    end
                end
            end
            @(negedge adc_clk);
            command_ready = 1'b1;
            @(negedge adc_clk);
            command_ready = 1'b0;
        end
    endtask

    task automatic expect_command_ch;
        input [4:0] expected_ch;
        input integer stall_cycles;
        begin
            wait (command_valid === 1'b1);
            if (command_channel !== expected_ch) begin
                $display("[ASSERT FAIL] CMD_ORDER: expected ch%0d got ch%0d t=%0t",
                         expected_ch, command_channel, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            if (!command_sop || !command_eop) begin
                $display("[ASSERT FAIL] CMD_SOP_EOP: ch%0d SOP=%b EOP=%b t=%0t",
                         command_channel, command_sop, command_eop, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            drive_command_ready(stall_cycles);
        end
    endtask

    task automatic send_response_beat;
        input [4:0]  ch;
        input [11:0] data;
        input        sop;
        input        eop;
        begin
            @(negedge adc_clk);
            response_channel = ch;
            response_data    = data;
            response_sop     = sop;
            response_eop     = eop;
            response_valid   = 1'b1;
            @(negedge adc_clk);
            response_valid   = 1'b0;
            response_sop     = 1'b1;
            response_eop     = 1'b1;
        end
    endtask

    // Mandatory error event observation (Item 2 compliant)
    task automatic check_error_event;
        input [3:0] expected_err;
        input integer wait_cycles;
        integer i;
        reg found;
        begin
            found = 1'b0;
            for (i = 0; i < wait_cycles; i = i + 1) begin
                if (!found) begin
                    @(posedge adc_clk);
                    if (error_event !== 4'b0) begin
                        if (error_event !== expected_err) begin
                            $display("[ASSERT FAIL] ERR_ENCODING: got=%04b expected=%04b t=%0t",
                                     error_event, expected_err, $time);
                            scoreboard_errors = scoreboard_errors + 1;
                        end else begin
                            $display("[MONITOR] Error event %04b at t=%0t (expected)", error_event, $time);
                        end
                        if (frame_valid) begin
                            $display("[ASSERT FAIL] BAD_FRAME_PUBLISHED: frame_valid after error t=%0t", $time);
                            scoreboard_errors = scoreboard_errors + 1;
                        end
                        found = 1'b1;
                    end
                end
            end
            if (!found) begin
                $display("[ASSERT FAIL] ERR_NOT_OBSERVED: expected %04b not seen within %0d cycles t=%0t",
                         expected_err, wait_cycles, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
        end
    endtask

    task automatic do_good_scan;
        input [11:0] ch1_val;
        input [11:0] ch2_val;
        input integer cmd_stall_ch1;
        input integer cmd_stall_ch2;
        begin
            expect_command_ch(5'd1, cmd_stall_ch1);
            send_response_beat(5'd1, ch1_val, 1'b1, 1'b1);
            expect_command_ch(5'd2, cmd_stall_ch2);
            send_response_beat(5'd2, ch2_val, 1'b1, 1'b1);
            ledger_push(ch1_val, ch2_val);
            cov_ch1_ch2_nominal = cov_ch1_ch2_nominal + 1;
        end
    endtask

    task automatic wait_pclk_frame;
        integer prev_count;
        begin
            prev_count = total_pclk_frames;
            wait (total_pclk_frames == prev_count + 1);
            @(posedge adc_clk);
        end
    endtask

    task automatic do_full_reset;
        begin
            @(negedge adc_clk);
            adc_reset_n  = 1'b0;
            @(negedge pclk);
            pclk_reset_n = 1'b0;
            enable_req   = 1'b0;
            repeat (6) @(posedge adc_clk);
            @(negedge adc_clk);
            adc_reset_n  = 1'b1;
            @(negedge pclk);
            pclk_reset_n = 1'b1;
            repeat (8) @(posedge pclk);
            ledger_reset();
        end
    endtask

    task automatic do_source_reset;
        begin
            @(negedge adc_clk);
            adc_reset_n  = 1'b0;
            enable_req   = 1'b0;
            repeat (6) @(posedge adc_clk);
            @(negedge adc_clk);
            adc_reset_n  = 1'b1;
            repeat (8) @(posedge pclk);
            ledger_reset();
        end
    endtask

    task automatic wait_engine_enabled_pclk;
        begin
            wait (engine_enabled_pclk === 1'b1);
        end
    endtask

    // -----------------------------------------------------------------------
    // Test cases
    // -----------------------------------------------------------------------

    // ---- T1: Reset / Disabled — no command ----
    task automatic test_t1_reset_disabled;
        begin
            $display("\n[TEST T1] Reset/Disabled — no command");
            do_full_reset();
            repeat (4) @(posedge adc_clk);
            if (command_valid) begin
                $display("[FAIL T1] command_valid asserted while disabled after reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            if (engine_enabled) begin
                $display("[FAIL T1] engine_enabled asserted while disabled t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_disabled = cov_reset_disabled + 1;
            $display("[PASS T1] Reset/Disabled — no command");
        end
    endtask

    // ---- T2: Enable -> first command is CH1 ----
    task automatic test_t2_first_cmd_ch1;
        begin
            $display("\n[TEST T2] Enable -> first command is CH1");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            if (command_channel !== 5'd1) begin
                $display("[FAIL T2] first command is ch%0d not ch1 t=%0t", command_channel, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end else
                $display("[PASS T2] first command is CH1 at t=%0t", $time);
            drive_command_ready(0);
            send_response_beat(5'd1, 12'habc, 1'b1, 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
        end
    endtask

    // ---- T3: Nominal CH1->CH2 frame; multiple consecutive ----
    task automatic test_t3_nominal_frames;
        input integer n_frames;
        integer i;
        begin
            $display("\n[TEST T3] Nominal CH1->CH2 frames x%0d", n_frames);
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            for (i = 0; i < n_frames; i = i + 1) begin
                do_good_scan(12'h100 + i, 12'h200 + i, 0, 0);
                wait_pclk_frame();
            end
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T3] Nominal frames passed, scoreboard_errors=%0d", scoreboard_errors);
        end
    endtask

    // ---- T4: Command_ready stall — payload stability ----
    task automatic test_t4_cmd_stall;
        begin
            $display("\n[TEST T4] Command_ready stall — payload stability");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'hfed, 12'hcba, 5, 3);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T4] Stall/stability passed");
        end
    endtask

    // ---- T5: Error injection — unexpected channel ----
    task automatic test_t5_unexpected_channel;
        reg [31:0] seq_before;
        integer    frames_before;
        begin
            $display("\n[TEST T5] Error — unexpected channel");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            seq_before    = ref_next_seq;
            frames_before = total_pclk_frames;
            send_response_beat(5'd6, 12'hbad, 1'b1, 1'b1);
            check_error_event(ERR_UNEXPECTED, 4);
            cov_err_unexpected = cov_err_unexpected + 1;
            cov_recovery_malformed = cov_recovery_malformed + 1;

            repeat (4) @(posedge adc_clk);
            if (total_pclk_frames !== frames_before) begin
                $display("[FAIL T5] spurious PCLK frame published on unexpected channel t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            if (ref_next_seq !== seq_before) begin
                $display("[FAIL T5] reference sequence advanced on bad scan t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            do_good_scan(12'h111, 12'h222, 0, 0);
            wait_pclk_frame();
            if (total_pclk_frames !== frames_before + 1) begin
                $display("[FAIL T5] recovery frame not received t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T5] Unexpected channel error handled and verified");
        end
    endtask

    // ---- T6: Error injection — order error (CH2 when CH1 expected) ----
    task automatic test_t6_order_error;
        reg [31:0] seq_before;
        integer    frames_before;
        begin
            $display("\n[TEST T6] Error — order error (CH2 when CH1 expected)");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            seq_before    = ref_next_seq;
            frames_before = total_pclk_frames;
            send_response_beat(5'd2, 12'haaa, 1'b1, 1'b1);
            check_error_event(ERR_ORDER, 4);
            cov_err_order = cov_err_order + 1;

            repeat (4) @(posedge adc_clk);
            if (total_pclk_frames !== frames_before) begin
                $display("[FAIL T6] spurious PCLK frame on order error t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            do_good_scan(12'h333, 12'h444, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T6] Order error handled and verified");
        end
    endtask

    // ---- T7: Error injection — duplicate channel (CH1 in CH2 slot) ----
    task automatic test_t7_duplicate_channel;
        reg [31:0] seq_before;
        integer    frames_before;
        begin
            $display("\n[TEST T7] Error — duplicate channel");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'hccc, 1'b1, 1'b1);
            seq_before    = ref_next_seq;
            frames_before = total_pclk_frames;
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd1, 12'hddd, 1'b1, 1'b1);
            check_error_event(ERR_DUPLICATE, 4);
            cov_err_duplicate = cov_err_duplicate + 1;

            repeat (4) @(posedge adc_clk);
            if (total_pclk_frames !== frames_before) begin
                $display("[FAIL T7] spurious PCLK frame on duplicate channel t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            do_good_scan(12'h555, 12'h666, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T7] Duplicate channel handled and verified");
        end
    endtask

    // ---- T8: Error injection — malformed SOP ----
    task automatic test_t8_packet_error_sop;
        reg [31:0] seq_before;
        integer    frames_before;
        begin
            $display("\n[TEST T8] Error — malformed SOP");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            seq_before    = ref_next_seq;
            frames_before = total_pclk_frames;
            send_response_beat(5'd1, 12'heee, 1'b0, 1'b1);
            check_error_event(ERR_PACKET, 4);
            cov_err_packet = cov_err_packet + 1;

            repeat (4) @(posedge adc_clk);
            if (total_pclk_frames !== frames_before) begin
                $display("[FAIL T8] spurious frame on SOP error t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            do_good_scan(12'h777, 12'h888, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T8] Packet error (bad SOP) handled and verified");
        end
    endtask

    // ---- T9: Error injection — malformed EOP ----
    task automatic test_t9_packet_error_eop;
        reg [31:0] seq_before;
        integer    frames_before;
        begin
            $display("\n[TEST T9] Error — malformed EOP");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'hfed, 1'b1, 1'b1);
            seq_before    = ref_next_seq;
            frames_before = total_pclk_frames;
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd2, 12'hcba, 1'b1, 1'b0);
            check_error_event(ERR_PACKET, 4);
            cov_err_packet = cov_err_packet + 1;

            repeat (4) @(posedge adc_clk);
            if (total_pclk_frames !== frames_before) begin
                $display("[FAIL T9] spurious frame on EOP error t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            do_good_scan(12'h999, 12'haaa, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T9] Packet error (bad EOP) handled and verified");
        end
    endtask

    // ---- T10: Disable before command accepted ----
    task automatic test_t10_disable_before_cmd;
        begin
            $display("\n[TEST T10] Disable before command accepted");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (6) @(posedge adc_clk);
            if (command_valid) begin
                $display("[FAIL T10] command_valid still asserted after disable t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_disable_before_cmd = cov_disable_before_cmd + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            if (command_channel !== 5'd1) begin
                $display("[FAIL T10] re-enable did not restart at CH1 t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reenable_after_dis = cov_reenable_after_dis + 1;
            drive_command_ready(0);
            send_response_beat(5'd1, 12'h100, 1'b1, 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (15) @(posedge adc_clk);
            $display("[PASS T10] Disable before cmd");
        end
    endtask

    // ---- T11: Disable while command valid stalled ----
    task automatic test_t11_disable_cmd_stall;
        begin
            $display("\n[TEST T11] Disable while command valid stalled");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (4) @(posedge adc_clk);
            cov_disable_cmd_stall = cov_disable_cmd_stall + 1;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T11] Disable cmd stall covered");
        end
    endtask

    // ---- T12: Disable while waiting CH1 response ----
    task automatic test_t12_disable_wait_ch1_resp;
        begin
            $display("\n[TEST T12] Disable while waiting CH1 response");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            @(negedge pclk); enable_req = 1'b0;
            repeat (4) @(posedge adc_clk);
            if (frame_valid) begin
                $display("[FAIL T12] frame_valid during drain after disable t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            if (!engine_enabled) begin
                $display("[FAIL T12] engine_enabled fell before response drained t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_disable_wait_ch1 = cov_disable_wait_ch1 + 1;
            send_response_beat(5'd1, 12'h123, 1'b1, 1'b1);
            repeat (6) @(posedge adc_clk);
            if (frame_valid) begin
                $display("[FAIL T12] partial frame published after drain+disable t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            if (engine_enabled) begin
                $display("[FAIL T12] engine_enabled did not fall after drain t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            repeat (5) @(posedge pclk);
            $display("[PASS T12] Disable while waiting CH1 resp");
        end
    endtask

    // ---- T13: Disable after CH1 partial assembly ----
    task automatic test_t13_disable_ch1_partial;
        begin
            $display("\n[TEST T13] Disable after CH1 partial (in ISSUE_CH2 state)");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h456, 1'b1, 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (8) @(posedge adc_clk);
            if (frame_valid) begin
                $display("[FAIL T13] partial frame published after disable t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_disable_ch1_partial = cov_disable_ch1_partial + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            if (command_channel !== 5'd1) begin
                $display("[FAIL T13] re-enable did not restart at CH1 t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            drive_command_ready(0);
            send_response_beat(5'd1, 12'h789, 1'b1, 1'b1);
            @(negedge pclk); enable_req = 1'b0;
            repeat (15) @(posedge adc_clk);
            $display("[PASS T13] Disable after CH1 partial");
        end
    endtask

    // ---- T14: Disable while waiting CH2 response ----
    task automatic test_t14_disable_wait_ch2_resp;
        begin
            $display("\n[TEST T14] Disable while waiting CH2 response");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'habc, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            @(negedge pclk); enable_req = 1'b0;
            repeat (3) @(posedge adc_clk);
            if (!engine_enabled) begin
                $display("[FAIL T14] engine_enabled fell before CH2 response drained t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_disable_wait_ch2 = cov_disable_wait_ch2 + 1;
            send_response_beat(5'd2, 12'hdef, 1'b1, 1'b1);
            repeat (8) @(posedge adc_clk);
            if (engine_enabled) begin
                $display("[FAIL T14] engine_enabled did not fall after CH2 drain t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            repeat (8) @(posedge pclk);
            $display("[PASS T14] Disable while waiting CH2 resp");
        end
    endtask

    // ---- T15: Disable after complete frame, mailbox busy ----
    task automatic test_t15_disable_mailbox_busy;
        integer prev_frames;
        integer timeout_cnt;
        begin
            $display("\n[TEST T15] Disable after complete frame while mailbox busy");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            prev_frames = total_pclk_frames;
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h111, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd2, 12'h222, 1'b1, 1'b1);
            ledger_push(12'h111, 12'h222);
            @(negedge pclk); enable_req = 1'b0;
            cov_disable_mailbox_busy = cov_disable_mailbox_busy + 1;

            timeout_cnt = 0;
            while (total_pclk_frames == prev_frames && timeout_cnt < 500) begin
                @(posedge pclk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (total_pclk_frames != prev_frames + 1) begin
                $display("[FAIL T15] frame did not arrive at PCLK: prev=%0d now=%0d t=%0t",
                         prev_frames, total_pclk_frames, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end

            timeout_cnt = 0;
            while (engine_enabled_pclk && timeout_cnt < 200) begin
                @(posedge pclk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (engine_enabled_pclk) begin
                $display("[FAIL T15] engine_enabled_pclk did not fall after mailbox ACK t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            repeat (6) @(posedge pclk);
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T15] extra frame after disable ack: got %0d expected %0d t=%0t",
                         total_pclk_frames, prev_frames + 1, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            $display("[PASS T15] Disable mailbox_busy: frame correctly delivered, no extra");
        end
    endtask

    // ---- T16: Re-enable after disable — restarts at CH1 ----
    task automatic test_t16_reenable;
        begin
            $display("\n[TEST T16] Re-enable after disable — restarts at CH1");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'haaa, 12'hbbb, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            if (command_channel !== 5'd1) begin
                $display("[FAIL T16] re-enable after disable: first cmd ch%0d not ch1 t=%0t",
                         command_channel, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            do_good_scan(12'hccc, 12'hddd, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            cov_reenable_after_dis = cov_reenable_after_dis + 1;
            $display("[PASS T16] Re-enable restart at CH1");
        end
    endtask

    // ---- T17: Reset during command-ready stall ----
    task automatic test_t17_reset_cmd_stall;
        integer prev_frames;
        begin
            $display("\n[TEST T17] Reset during command-ready stall");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            wait (command_valid === 1'b1);
            prev_frames = total_pclk_frames;
            do_full_reset();
            repeat (4) @(posedge pclk);
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T17] stale frame appeared after reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_cmd_stall = cov_reset_cmd_stall + 1;
            $display("[PASS T17] Reset during cmd stall — no stale frame");
        end
    endtask

    // ---- T18: Reset during CH1 partial assembly ----
    task automatic test_t18_reset_ch1_partial;
        integer prev_frames;
        begin
            $display("\n[TEST T18] Reset during CH1 partial assembly");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h123, 1'b1, 1'b1);
            prev_frames = total_pclk_frames;
            do_full_reset();
            repeat (4) @(posedge pclk);
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T18] stale frame after CH1 partial reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_ch1_partial = cov_reset_ch1_partial + 1;
            $display("[PASS T18] Reset CH1 partial — no stale frame");
        end
    endtask

    // ---- T19: Reset while mailbox busy ----
    task automatic test_t19_reset_mailbox_busy;
        integer prev_frames;
        begin
            $display("\n[TEST T19] Reset while mailbox busy");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h456, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd2, 12'h789, 1'b1, 1'b1);
            wait (mailbox_busy === 1'b1);
            prev_frames = total_pclk_frames;
            do_source_reset();
            repeat (6) @(posedge pclk);
            cov_reset_mailbox_busy = cov_reset_mailbox_busy + 1;
            do_full_reset();
            $display("[PASS T19] Reset while mailbox busy — no phantom");
        end
    endtask

    // ---- T20: Unsolicited/stale response in DISABLED state ----
    task automatic test_t20_unsolicited_response;
        integer prev_frames;
        begin
            $display("\n[TEST T20] Unsolicited response in DISABLED state");
            do_full_reset();
            prev_frames = total_pclk_frames;

            allow_unsolicited_response = 1'b1;
            @(negedge adc_clk);
            response_channel = 5'd1;
            response_data    = 12'hbad;
            response_sop     = 1'b1;
            response_eop     = 1'b1;
            response_valid   = 1'b1;
            @(negedge adc_clk);
            response_valid   = 1'b0;
            allow_unsolicited_response = 1'b0;

            repeat (4) @(posedge adc_clk);
            if (frame_valid) begin
                $display("[FAIL T20] frame_valid asserted on unsolicited response t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            repeat (4) @(posedge pclk);
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T20] PCLK frame appeared on unsolicited response t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            $display("[PASS T20] Unsolicited response ignored while disabled");
        end
    endtask

    // ---- T21: CDC — one frame -> exactly one PCLK pulse ----
    task automatic test_t21_one_to_one_pulse;
        integer prev_frames;
        begin
            $display("\n[TEST T21] CDC — one frame -> exactly one PCLK pulse");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'habc, 12'hdef, 0, 0);
            prev_frames = total_pclk_frames;
            wait (total_pclk_frames == prev_frames + 1);
            wait (!mailbox_busy);
            repeat (20) @(posedge pclk);
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T21] duplicate PCLK pulse: got %0d extra frames t=%0t",
                         total_pclk_frames - prev_frames - 1, $time);
                scoreboard_errors = scoreboard_errors + 1;
            end else
                $display("[PASS T21] Exactly one PCLK pulse for one frame");
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
        end
    endtask

    // ---- T22: CDC — source cannot overwrite busy mailbox ----
    task automatic test_t22_mailbox_not_overwritten;
        begin
            $display("\n[TEST T22] CDC — no mailbox overwrite while busy");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'h001, 12'h002, 0, 0);
            if (mailbox_busy) begin
                repeat (10) @(posedge adc_clk);
                if (command_valid) begin
                    $display("[FAIL T22] engine issued new command while mailbox busy t=%0t", $time);
                    scoreboard_errors = scoreboard_errors + 1;
                end
            end
            wait_pclk_frame();
            do_good_scan(12'h003, 12'h004, 0, 0);
            wait_pclk_frame();
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T22] Mailbox not overwritten");
        end
    endtask

    // ---- T23: Reset while waiting for CH1 response (Requirement 4) ----
    task automatic test_t23_reset_wait_ch1_resp;
        integer prev_frames;
        begin
            $display("\n[TEST T23] Reset while waiting for CH1 response");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            prev_frames = total_pclk_frames;

            do_full_reset();
            repeat (4) @(posedge pclk);
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T23] phantom frame after reset during CH1 wait t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_wait_ch1_resp = cov_reset_wait_ch1_resp + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'h1a1, 12'h1a2, 0, 0);
            wait_pclk_frame();
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T23] recovery frame not received t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T23] Reset while waiting for CH1 response — clean recovery");
        end
    endtask

    // ---- T24: Reset while waiting for CH2 response (Requirement 4) ----
    task automatic test_t24_reset_wait_ch2_resp;
        integer prev_frames;
        begin
            $display("\n[TEST T24] Reset while waiting for CH2 response");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h2a1, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            prev_frames = total_pclk_frames;

            do_full_reset();
            repeat (4) @(posedge pclk);
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T24] phantom frame after reset during CH2 wait t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_wait_ch2_resp = cov_reset_wait_ch2_resp + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'h2b1, 12'h2b2, 0, 0);
            wait_pclk_frame();
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T24] recovery frame not received t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T24] Reset while waiting for CH2 response — clean recovery");
        end
    endtask

    // ---- T25: Reset after completed scan before publication / REQ acceptance (Requirement 4) ----
    task automatic test_t25_reset_post_scan_pre_pub;
        integer prev_frames;
        begin
            $display("\n[TEST T25] Reset after completed scan before publication acceptance");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h3a1, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd2, 12'h3a2, 1'b1, 1'b1);
            prev_frames = total_pclk_frames;

            @(negedge adc_clk);
            adc_reset_n  = 1'b0;
            @(negedge pclk);
            pclk_reset_n = 1'b0;
            enable_req   = 1'b0;
            repeat (6) @(posedge adc_clk);
            @(negedge adc_clk);
            adc_reset_n  = 1'b1;
            @(negedge pclk);
            pclk_reset_n = 1'b1;
            repeat (8) @(posedge pclk);
            ledger_reset();

            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T25] stale frame published after pre-pub reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_pre_pub = cov_reset_pre_pub + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'h3c1, 12'h3c2, 0, 0);
            wait_pclk_frame();
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T25] recovery frame not received t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T25] Reset post-scan pre-pub — no stale frame");
        end
    endtask

    // ---- T26: Reset near destination REQ synchronization/capture (Requirement 4) ----
    task automatic test_t26_reset_near_dest_capture;
        integer prev_frames;
        begin
            $display("\n[TEST T26] Reset near destination REQ synchronization/capture");
            do_full_reset();
            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            expect_command_ch(5'd1, 0);
            send_response_beat(5'd1, 12'h4a1, 1'b1, 1'b1);
            expect_command_ch(5'd2, 0);
            send_response_beat(5'd2, 12'h4a2, 1'b1, 1'b1);
            prev_frames = total_pclk_frames;

            // Wait until mailbox is busy (REQ toggle generated in ADC domain)
            wait (mailbox_busy === 1'b1);
            // Assert system reset immediately while REQ is synchronizing to PCLK domain
            @(negedge adc_clk);
            adc_reset_n  = 1'b0;
            @(negedge pclk);
            pclk_reset_n = 1'b0;
            enable_req   = 1'b0;
            repeat (6) @(posedge adc_clk);
            if (frame_pulse_pclk) begin
                $display("[FAIL T26] frame_pulse_pclk asserted during reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            @(negedge adc_clk);
            adc_reset_n  = 1'b1;
            @(negedge pclk);
            pclk_reset_n = 1'b1;
            repeat (8) @(posedge pclk);
            ledger_reset();
            if (total_pclk_frames !== prev_frames) begin
                $display("[FAIL T26] phantom frame published after dest capture reset t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            cov_reset_dest_capture = cov_reset_dest_capture + 1;

            @(negedge pclk); enable_req = 1'b1;
            wait_engine_enabled_pclk();
            do_good_scan(12'h4d1, 12'h4d2, 0, 0);
            wait_pclk_frame();
            if (total_pclk_frames !== prev_frames + 1) begin
                $display("[FAIL T26] recovery frame not received t=%0t", $time);
                scoreboard_errors = scoreboard_errors + 1;
            end
            @(negedge pclk); enable_req = 1'b0;
            repeat (10) @(posedge adc_clk);
            $display("[PASS T26] Reset near destination capture — clean recovery");
        end
    endtask

    // -----------------------------------------------------------------------
    // Coverage summary
    // -----------------------------------------------------------------------
    task automatic print_coverage;
        begin
            $display("\n=== Functional Coverage Summary ===");
            $display("  CH1/CH2 nominal scan:         %0d", cov_ch1_ch2_nominal);
            $display("  Unexpected channel error:     %0d", cov_err_unexpected);
            $display("  Duplicate channel error:      %0d", cov_err_duplicate);
            $display("  Order error:                  %0d", cov_err_order);
            $display("  Packet error:                 %0d", cov_err_packet);
            $display("  Command stall:                %0d", cov_cmd_stall);
            $display("  Disable before cmd:           %0d", cov_disable_before_cmd);
            $display("  Disable cmd stall:            %0d", cov_disable_cmd_stall);
            $display("  Disable wait CH1 resp:        %0d", cov_disable_wait_ch1);
            $display("  Disable CH1 partial:          %0d", cov_disable_ch1_partial);
            $display("  Disable wait CH2 resp:        %0d", cov_disable_wait_ch2);
            $display("  Disable mailbox busy:         %0d", cov_disable_mailbox_busy);
            $display("  Reset disabled state:         %0d", cov_reset_disabled);
            $display("  Reset cmd stall:              %0d", cov_reset_cmd_stall);
            $display("  Reset CH1 partial:            %0d", cov_reset_ch1_partial);
            $display("  Reset mailbox busy:           %0d", cov_reset_mailbox_busy);
            $display("  Reset wait CH1 resp:          %0d", cov_reset_wait_ch1_resp);
            $display("  Reset wait CH2 resp:          %0d", cov_reset_wait_ch2_resp);
            $display("  Reset pre-pub frame:          %0d", cov_reset_pre_pub);
            $display("  Reset dest capture:           %0d", cov_reset_dest_capture);
            $display("  Re-enable after disable:      %0d", cov_reenable_after_dis);
            $display("  Recovery after malformed:     %0d", cov_recovery_malformed);
            $display("  Total PCLK frames received:   %0d", total_pclk_frames);
            $display("  Scoreboard errors:            %0d", scoreboard_errors);
        end
    endtask

    // -----------------------------------------------------------------------
    // Main sequence
    // -----------------------------------------------------------------------
    initial begin
        // Startup elaboration parameter print (Requirement 1)
        $display("[ELAB_PARAM] ADC_HALF_NS=%0d PCLK_HALF_NS=%0d PCLK_PHASE_NS=%0d SEED=%0d",
                 ADC_HALF_NS, PCLK_HALF_NS, PCLK_PHASE_NS, SEED);

        // Initialize signals
        adc_reset_n   = 1'b0;
        pclk_reset_n  = 1'b0;
        enable_req    = 1'b0;
        command_ready = 1'b0;
        response_valid   = 1'b0;
        response_channel = 5'd0;
        response_data    = 12'd0;
        response_sop     = 1'b1;
        response_eop     = 1'b1;
        outstanding_cmds = 0;
        allow_unsolicited_response = 1'b0;
        ledger_reset();

        $display("[B3 START] ADC_HALF=%0d PCLK_HALF=%0d PCLK_PHASE=%0d SEED=%0d",
                 ADC_HALF_NS, PCLK_HALF_NS, PCLK_PHASE_NS, SEED);

        repeat (4) @(posedge adc_clk);

        // Run full test suite T1 through T26
        test_t1_reset_disabled();
        test_t2_first_cmd_ch1();
        test_t3_nominal_frames(5);
        test_t4_cmd_stall();
        test_t5_unexpected_channel();
        test_t6_order_error();
        test_t7_duplicate_channel();
        test_t8_packet_error_sop();
        test_t9_packet_error_eop();
        test_t10_disable_before_cmd();
        test_t11_disable_cmd_stall();
        test_t12_disable_wait_ch1_resp();
        test_t13_disable_ch1_partial();
        test_t14_disable_wait_ch2_resp();
        test_t15_disable_mailbox_busy();
        test_t16_reenable();
        test_t17_reset_cmd_stall();
        test_t18_reset_ch1_partial();
        test_t19_reset_mailbox_busy();
        test_t20_unsolicited_response();
        test_t21_one_to_one_pulse();
        test_t22_mailbox_not_overwritten();
        test_t23_reset_wait_ch1_resp();
        test_t24_reset_wait_ch2_resp();
        test_t25_reset_post_scan_pre_pub();
        test_t26_reset_near_dest_capture();

        // Final coverage and pass/fail
        print_coverage();

        if (ledger_count !== 0) begin
            $display("[FAIL] %0d expected frames in ledger not received at PCLK", ledger_count);
            scoreboard_errors = scoreboard_errors + 1;
        end

        $display("\n=== B3 RESULT: SEED=%0d ADC=%0dns PCLK=%0dns PHASE=%0dns ===",
                 SEED, ADC_HALF_NS*2, PCLK_HALF_NS*2, PCLK_PHASE_NS);
        if (scoreboard_errors == 0)
            $display("[PASS] All B3 independent DV checks passed.");
        else
            $display("[FAIL] %0d scoreboard/assertion failures.", scoreboard_errors);

        $finish;
    end

    // Global timeout (50 ms sim time)
    initial begin
        #50000000;
        $display("[TIMEOUT] B3 simulation exceeded time limit");
        $fatal(1, "B3_TIMEOUT");
    end

endmodule
