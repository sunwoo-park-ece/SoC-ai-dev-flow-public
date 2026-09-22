`timescale 1ns/1ps
module tb_hex_s5_cpu_e2e;
    reg clk = 0;
    reg [1:0] KEY = 2'b10;
    reg [9:0] SW = 0;
    reg [2:1] G_SENSOR_INT = 0;
    reg G_SENSOR_SDO = 0, lora_rx = 1, lora_aux = 0, uart_rx = 1;
    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire G_SENSOR_CS_N, G_SENSOR_SCLK, G_SENSOR_SDI;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire VGA_HS, VGA_VS, lora_tx, uart_tx;

    integer cycle;
    integer checks = 0;
    reg inject_l3_fault = 0;

    always #5 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI), .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    task check_step(input string step_name);
        begin
            checks = checks + 1;
        end
    endtask

    task reset_cpu;
        integer r;
        begin
            force dut.PRESETN_SYS = 0;
            for (r = 1; r < 32; r = r + 1)
                dut.u_CPU.register_file.registers[r] = 32'd0;
            dut.u_CPU.csr_file.mcause = 32'd0;
            dut.u_CPU.csr_file.mepc = 32'd0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            force dut.PRESETN_SYS = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    reg [23:0] ref_val;
    reg [1:0]  ref_ctrl;
    reg [20:0] ref_raw_l, ref_raw_h;
    reg [6:0]  ref_h0, ref_h1, ref_h2, ref_h3, ref_h4, ref_h5;

    task init_hex_state;
        begin
            dut.u_hex_display.value_reg    = 24'h123456;
            dut.u_hex_display.ctrl_reg     = 2'b11; // ENABLE=1, RAW_MODE=1
            dut.u_hex_display.raw_low_reg  = 21'h125212;
            dut.u_hex_display.raw_high_reg = 21'h15580f;
            #1;
            ref_val   = dut.u_hex_display.value_reg;
            ref_ctrl  = dut.u_hex_display.ctrl_reg;
            ref_raw_l = dut.u_hex_display.raw_low_reg;
            ref_raw_h = dut.u_hex_display.raw_high_reg;
            ref_h0 = HEX0; ref_h1 = HEX1; ref_h2 = HEX2;
            ref_h3 = HEX3; ref_h4 = HEX4; ref_h5 = HEX5;
        end
    endtask

    task verify_hex_state_immutability(input string case_name);
        begin
            if (dut.u_hex_display.value_reg !== ref_val ||
                dut.u_hex_display.ctrl_reg !== ref_ctrl ||
                dut.u_hex_display.raw_low_reg !== ref_raw_l ||
                dut.u_hex_display.raw_high_reg !== ref_raw_h ||
                HEX0 !== ref_h0 || HEX1 !== ref_h1 || HEX2 !== ref_h2 ||
                HEX3 !== ref_h3 || HEX4 !== ref_h4 || HEX5 !== ref_h5)
                $fatal(1, "L3_SIDE_EFFECT_FAIL: %s — HEX state/pins mutated during fault!", case_name);
        end
    endtask

    // Program a test sequence for trap cases:
    //   word[0] (PC=0): lui x1, 0x40070
    //   word[1] (PC=4): setup_inst (sets up x2)
    //   word[2] (PC=8): target_inst (faulting access)
    //   word[3] (PC=12): addi x3, x0, 1 (younger instruction)
    //   word[4] (PC=16): j . (spin loop)
    task program_trap_seq(input [31:0] setup_inst, input [31:0] target_inst);
        begin
            dut.u_CPU.if_id_register.u_IMEM.words[0] = 32'h400700b7; // lui x1, 0x40070
            dut.u_CPU.if_id_register.u_IMEM.words[1] = setup_inst;   // e.g. addi x2, x0, val
            dut.u_CPU.if_id_register.u_IMEM.words[2] = target_inst;  // faulting load/store
            dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h00100193; // addi x3, x0, 1
            dut.u_CPU.if_id_register.u_IMEM.words[4] = 32'h0000006f; // j PC+0 (spin loop)
        end
    endtask

    // Run CPU test case expecting an architectural trap with specific mcause.
    // Run CPU test case expecting an architectural trap with specific mcause.
    // Explicitly distinguishes Bridge Access Fault (bus request emitted, PSEL suppressed, 2-cycle HRESP ERROR)
    // from CPU Alignment Fault (core internal trap, bus request suppressed, HTRANS IDLE).
    task run_trap_case(
        input [31:0] expected_cause,
        input [31:0] expected_x2,
        input is_bridge_fault,
        input [31:0] exp_addr,
        input [2:0]  exp_size,
        input string case_name
    );
        reg trap_seen;
        reg ahb_req_matched;
        reg psel_leaked;
        integer err_cyc1_count;
        integer err_cyc2_count;
        reg cpu_align_bus_idle;
        reg cpu_align_ahb_req;
        reg cpu_align_bridge_err;
        begin : wait_trap
            trap_seen = 0;
            ahb_req_matched = 0;
            psel_leaked = 0;
            err_cyc1_count = 0;
            err_cyc2_count = 0;
            cpu_align_bus_idle = 1;
            cpu_align_ahb_req = 0;
            cpu_align_bridge_err = 0;

            for (cycle = 0; cycle < 150; cycle = cycle + 1) begin
                @(posedge clk); #1;

                if (is_bridge_fault) begin
                    // 1. Monitor AHB request: address phase must match expected addr and size
                    if (dut.HSEL_APB && dut.HTRANS[1]) begin
                        if (dut.HADDR === exp_addr && dut.HSIZE === exp_size) begin
                            ahb_req_matched = 1;
                        end
                        // SETUP interval: PSEL must be 0
                        if (dut.PSEL !== 16'h0000) begin
                            psel_leaked = 1;
                        end
                    end
                    // ACCESS interval: PSEL must remain 0
                    if (dut.HSEL_APB_d) begin
                        if (dut.PSEL !== 16'h0000) begin
                            psel_leaked = 1;
                        end
                        // Count first ERROR cycle: HRESP=2'b01, HREADY=0
                        if (dut.HRESP === 2'b01 && dut.HREADY === 1'b0) begin
                            err_cyc1_count = err_cyc1_count + 1;
                        end
                        // Count second ERROR cycle: HRESP=2'b01, HREADY=1
                        else if (dut.HRESP === 2'b01 && dut.HREADY === 1'b1) begin
                            err_cyc2_count = err_cyc2_count + 1;
                        end
                    end
                end else begin
                    // CPU Alignment fault: CPU core must NOT emit memory request to AHB bus
                    if (dut.u_CPU.EX_memory_read_AHB || dut.u_CPU.EX_memory_write_AHB) begin
                        cpu_align_bus_idle = 0;
                    end
                    // Monitor AHB bus signals: HSEL_APB and HTRANS must not assert a bus request
                    if (dut.HSEL_APB && dut.HTRANS[1]) begin
                        cpu_align_ahb_req = 1;
                    end
                    // Monitor Bridge HRESP: no Bridge ERROR response should ever be generated
                    if (dut.HRESP === 2'b01) begin
                        cpu_align_bridge_err = 1;
                    end
                end

                // Injected fault (Mutation mode): simulate Bridge ERROR masking
                if (inject_l3_fault) begin
                    force dut.HRESP = 2'b00;
                end

                if (dut.u_CPU.csr_file.mcause == expected_cause) begin
                    trap_seen = 1;

                    // Architectural Trap checks
                    if (dut.u_CPU.csr_file.mepc !== 32'd8)
                        $fatal(1, "L3_MEPC_MISMATCH: %s — got mepc=%h, expected=8",
                               case_name, dut.u_CPU.csr_file.mepc);
                    if (dut.u_CPU.register_file.registers[2] !== expected_x2)
                        $fatal(1, "L3_RD_CORRUPT: %s — x2 changed to %h, expected=%h",
                               case_name, dut.u_CPU.register_file.registers[2], expected_x2);

                    if (is_bridge_fault) begin
                        // Verification of exact Bridge ERROR sequence
                        if (!ahb_req_matched)
                            $fatal(1, "L3_REQ_MISMATCH: %s — CPU did not emit matching AHB request (addr=%h size=%b)",
                                   case_name, exp_addr, exp_size);
                        if (psel_leaked)
                            $fatal(1, "L3_PSEL_NOT_SUPPRESSED: %s — PSEL was asserted (not 0) during invalid access", case_name);
                        if (err_cyc1_count !== 1)
                            $fatal(1, "L3_ERR_CYC1_COUNT: %s — cycle 1 ERROR (HRESP=01, HREADY=0) observed %0d times (expected 1)",
                                   case_name, err_cyc1_count);
                        if (err_cyc2_count !== 1)
                            $fatal(1, "L3_ERR_CYC2_COUNT: %s — cycle 2 ERROR (HRESP=01, HREADY=1) observed %0d times (expected 1)",
                                   case_name, err_cyc2_count);
                    end else begin
                        if (!cpu_align_bus_idle)
                            $fatal(1, "L3_ALIGN_BUS_ACTIVE: %s — CPU leaked EX memory request during alignment fault", case_name);
                        if (cpu_align_ahb_req)
                            $fatal(1, "L3_ALIGN_AHB_REQ: %s — CPU asserted AHB request (HSEL_APB=1, HTRANS=%b) during alignment fault",
                                   case_name, dut.HTRANS);
                        if (cpu_align_bridge_err)
                            $fatal(1, "L3_ALIGN_BRIDGE_ERROR: %s — Bridge ERROR occurred during alignment fault (HRESP=%b)",
                                   case_name, dut.HRESP);
                    end

                    // Check younger instruction (addi x3, x0, 1) cancellation
                    repeat (15) @(posedge clk); #1;
                    if (dut.u_CPU.register_file.registers[3] !== 32'd0)
                        $fatal(1, "L3_YOUNGER_SURVIVED: %s — younger instruction committed (x3=%h)",
                               case_name, dut.u_CPU.register_file.registers[3]);

                    // Verify state immutability across and after fault
                    verify_hex_state_immutability(case_name);

                    if (is_bridge_fault) begin
                        $display("[L3 TRAP PASS] %s: mcause=%0d mepc=%h (addr_match=OK, psel_suppr=OK, cyc1=1, cyc2=1, rd_intact=OK, cancel=OK)",
                                 case_name, dut.u_CPU.csr_file.mcause, dut.u_CPU.csr_file.mepc);
                    end else begin
                        $display("[L3 TRAP PASS] %s: mcause=%0d mepc=%h (align_trap=OK, bus_idle=OK, ahb_req=NONE, bridge_err=NONE, rd_intact=OK, cancel=OK)",
                                 case_name, dut.u_CPU.csr_file.mcause, dut.u_CPU.csr_file.mepc);
                    end
                    check_step(case_name);
                    disable wait_trap;
                end
            end
            if (!trap_seen)
                $fatal(1, "L3_TRAP_TIMEOUT: %s — did not trap with cause=%0d (mcause=%h, pc=%h, hresp=%b, hready=%b)",
                       case_name, expected_cause, dut.u_CPU.csr_file.mcause, dut.u_CPU.pc, dut.HRESP, dut.HREADY);
        end
    endtask

    // Run normal CPU case expecting successful instruction retirement without trap (V01, AC-V05)
    task run_normal_case(input [31:0] exp_x2, input string case_name);
        begin : wait_normal
            for (cycle = 0; cycle < 150; cycle = cycle + 1) begin
                @(posedge clk); #1;
                if (dut.u_CPU.csr_file.mcause !== 32'd0)
                    $fatal(1, "L3_UNEXPECTED_TRAP: %s — unexpected mcause=%0d at pc=%h",
                           case_name, dut.u_CPU.csr_file.mcause, dut.u_CPU.pc);
                // When younger instruction (addi x3, x0, 1) has retired
                if (dut.u_CPU.register_file.registers[3] === 32'd1) begin
                    if (dut.u_CPU.register_file.registers[2] !== exp_x2)
                        $fatal(1, "L3_NORMAL_RD_FAIL: %s — x2 got %h, expected %h",
                               case_name, dut.u_CPU.register_file.registers[2], exp_x2);
                    $display("[L3 NORMAL PASS] %s: x2=%h retired in %0d cycles (no trap)",
                             case_name, dut.u_CPU.register_file.registers[2], cycle);
                    check_step(case_name);
                    disable wait_normal;
                end
            end
            $fatal(1, "L3_NORMAL_TIMEOUT: %s — instruction retirement timed out (x3=%h, pc=%h)",
                   case_name, dut.u_CPU.register_file.registers[3], dut.u_CPU.pc);
        end
    endtask

    initial begin
        if ($test$plusargs("INJECT_L3_BUS_FAULT") || $test$plusargs("INJECT_L3_MCAUSE_FAULT")) begin
            inject_l3_fault = 1;
            $display("[MUTATION] INJECT_L3_BUS_FAULT enabled: masking Bridge HRESP ERROR");
        end

        // =========================================================================
        // Step 1: Normal CPU Write & Readback to ALL 4 HEX Registers (V01, AC-V05)
        // =========================================================================

        // --- Sequence 1: Write & Readback HEX_VALUE (0x4007_0000) ---
        // Assembler:
        //   PC=0:  lui x1, 0x40070       -> 32'h400700b7
        //   PC=4:  lui x2, 0x123         -> 32'h00123137
        //   PC=8:  addi x2, x2, 0x456    -> 32'h45610113 (x2 = 0x00123456)
        //   PC=12: sw x2, 0(x1)          -> 32'h0020a023 (write to VALUE)
        //   PC=16: addi x2, x0, 0        -> 32'h00000113 (clear x2)
        //   PC=20: lw x2, 0(x1)          -> 32'h0000a103 (readback VALUE into x2)
        //   PC=24: addi x3, x0, 1        -> 32'h00100193 (younger retirement marker)
        //   PC=28: j PC+0                -> 32'h0000006f
        dut.u_CPU.if_id_register.u_IMEM.words[0] = 32'h400700b7;
        dut.u_CPU.if_id_register.u_IMEM.words[1] = 32'h00123137;
        dut.u_CPU.if_id_register.u_IMEM.words[2] = 32'h45610113;
        dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h0020a023;
        dut.u_CPU.if_id_register.u_IMEM.words[4] = 32'h00000113;
        dut.u_CPU.if_id_register.u_IMEM.words[5] = 32'h0000a103;
        dut.u_CPU.if_id_register.u_IMEM.words[6] = 32'h00100193;
        dut.u_CPU.if_id_register.u_IMEM.words[7] = 32'h0000006f;
        reset_cpu();
        run_normal_case(32'h00123456, "L3_NORMAL_SW_LW_VALUE");
        if (dut.u_hex_display.value_reg !== 24'h123456)
            $fatal(1, "L3_HEX_VALUE_NOT_WRITTEN: value_reg got %h exp 00123456", dut.u_hex_display.value_reg);
        // In decoder mode (default CTRL=1): check decoded 7-seg pins
        // Digit 1=6 (0000010), 2=5 (0010010), 3=4 (0011001), 4=3 (0110000), 5=2 (0100100), 6=1 (1111001)
        if (HEX0 !== 7'b0000010 || HEX1 !== 7'b0010010 || HEX2 !== 7'b0011001 ||
            HEX3 !== 7'b0110000 || HEX4 !== 7'b0100100 || HEX5 !== 7'b1111001)
            $fatal(1, "L3_HEX_DECODER_PINS_FAIL: decoded pins mismatch for 0x123456");
        check_step("L3_NORMAL_VAL_OUTPUT_CHECK");

        // --- Sequence 2: Write & Readback HEX_CTRL (0x4007_0004) ---
        // Assembler:
        //   PC=0:  lui x1, 0x40070       -> 32'h400700b7
        //   PC=4:  addi x2, x0, 0        -> 32'h00000113 (x2 = 0: ENABLE=0 -> BLANK)
        //   PC=8:  sw x2, 4(x1)          -> 32'h0020a223 (write 0 to CTRL)
        //   PC=12: addi x2, x0, 0x7f     -> 32'h07f00113 (dummy in x2)
        //   PC=16: lw x2, 4(x1)          -> 32'h0040a103 (readback CTRL into x2)
        //   PC=20: addi x3, x0, 1        -> 32'h00100193
        //   PC=24: j PC+0                -> 32'h0000006f
        dut.u_CPU.if_id_register.u_IMEM.words[0] = 32'h400700b7;
        dut.u_CPU.if_id_register.u_IMEM.words[1] = 32'h00000113;
        dut.u_CPU.if_id_register.u_IMEM.words[2] = 32'h0020a223;
        dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h07f00113;
        dut.u_CPU.if_id_register.u_IMEM.words[4] = 32'h0040a103;
        dut.u_CPU.if_id_register.u_IMEM.words[5] = 32'h00100193;
        dut.u_CPU.if_id_register.u_IMEM.words[6] = 32'h0000006f;
        reset_cpu();
        run_normal_case(32'h0, "L3_NORMAL_SW_LW_CTRL");
        if (dut.u_hex_display.ctrl_reg !== 2'b00)
            $fatal(1, "L3_HEX_CTRL_NOT_WRITTEN: ctrl_reg got %h exp 00", dut.u_hex_display.ctrl_reg);
        // Since ENABLE=0, all outputs must be BLANK (7'b1111111)
        if (HEX0 !== 7'b1111111 || HEX1 !== 7'b1111111 || HEX2 !== 7'b1111111 ||
            HEX3 !== 7'b1111111 || HEX4 !== 7'b1111111 || HEX5 !== 7'b1111111)
            $fatal(1, "L3_HEX_DISABLE_BLANK_FAIL: outputs not blanked when ENABLE=0");
        check_step("L3_NORMAL_CTRL_BLANK_CHECK");

        // --- Sequence 3: Write & Readback HEX_RAW_LOW (0x4007_0008) ---
        // Assembler:
        //   PC=0:  lui x1, 0x40070       -> 32'h400700b7
        //   PC=4:  addi x2, x0, 3        -> 32'h00300113 (CTRL = 3: ENABLE=1, RAW_MODE=1)
        //   PC=8:  sw x2, 4(x1)          -> 32'h0020a223
        //   PC=12: lui x2, 0x125         -> 32'h00125137
        //   PC=16: addi x2, x2, 530      -> 32'h21210113 (x2 = 0x00125212)
        //   PC=20: sw x2, 8(x1)          -> 32'h0020a423 (write RAW_LOW)
        //   PC=24: addi x2, x0, 0        -> 32'h00000113 (clear x2)
        //   PC=28: lw x2, 8(x1)          -> 32'h0080a103 (readback RAW_LOW)
        //   PC=32: addi x3, x0, 1        -> 32'h00100193
        //   PC=36: j PC+0                -> 32'h0000006f
        dut.u_CPU.if_id_register.u_IMEM.words[0] = 32'h400700b7;
        dut.u_CPU.if_id_register.u_IMEM.words[1] = 32'h00300113;
        dut.u_CPU.if_id_register.u_IMEM.words[2] = 32'h0020a223;
        dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h00125137;
        dut.u_CPU.if_id_register.u_IMEM.words[4] = 32'h21210113;
        dut.u_CPU.if_id_register.u_IMEM.words[5] = 32'h0020a423;
        dut.u_CPU.if_id_register.u_IMEM.words[6] = 32'h00000113;
        dut.u_CPU.if_id_register.u_IMEM.words[7] = 32'h0080a103;
        dut.u_CPU.if_id_register.u_IMEM.words[8] = 32'h00100193;
        dut.u_CPU.if_id_register.u_IMEM.words[9] = 32'h0000006f;
        reset_cpu();
        run_normal_case(32'h00125212, "L3_NORMAL_SW_LW_RAW_LOW");
        if (dut.u_hex_display.raw_low_reg !== 21'h125212)
            $fatal(1, "L3_HEX_RAWL_NOT_WRITTEN: raw_low_reg got %h exp 125212", dut.u_hex_display.raw_low_reg);
        // 21'h125212 = {7'b1001001 (HEX2), 7'b0100100 (HEX1), 7'b0010010 (HEX0)}
        if (HEX0 !== 7'b0010010 || HEX1 !== 7'b0100100 || HEX2 !== 7'b1001001)
            $fatal(1, "L3_RAW_LOW_PINS_FAIL: HEX0~2 pins mismatch for 0x125212");
        check_step("L3_NORMAL_RAW_LOW_OUTPUT_CHECK");

        // --- Sequence 4: Write & Readback HEX_RAW_HIGH (0x4007_000C) ---
        // Assembler:
        //   PC=0:  lui x1, 0x40070       -> 32'h400700b7
        //   PC=4:  addi x2, x0, 3        -> 32'h00300113 (CTRL = 3: ENABLE=1, RAW_MODE=1)
        //   PC=8:  sw x2, 4(x1)          -> 32'h0020a223
        //   PC=12: lui x2, 0x125         -> 32'h00125137
        //   PC=16: addi x2, x2, 530      -> 32'h21210113 (RAW_LOW = 0x125212)
        //   PC=20: sw x2, 8(x1)          -> 32'h0020a423
        //   PC=24: lui x2, 0x156         -> 32'h00156137
        //   PC=28: addi x2, x2, -2033    -> 32'h80f10113 (RAW_HIGH = 0x15580f)
        //   PC=32: sw x2, 12(x1)         -> 32'h0020a623
        //   PC=36: addi x2, x0, 0        -> 32'h00000113 (clear x2)
        //   PC=40: lw x2, 12(x1)         -> 32'h00c0a103 (readback RAW_HIGH)
        //   PC=44: addi x3, x0, 1        -> 32'h00100193
        //   PC=48: j PC+0                -> 32'h0000006f
        dut.u_CPU.if_id_register.u_IMEM.words[0] = 32'h400700b7;
        dut.u_CPU.if_id_register.u_IMEM.words[1] = 32'h00300113;
        dut.u_CPU.if_id_register.u_IMEM.words[2] = 32'h0020a223;
        dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h00125137;
        dut.u_CPU.if_id_register.u_IMEM.words[4] = 32'h21210113;
        dut.u_CPU.if_id_register.u_IMEM.words[5] = 32'h0020a423;
        dut.u_CPU.if_id_register.u_IMEM.words[6] = 32'h00156137;
        dut.u_CPU.if_id_register.u_IMEM.words[7] = 32'h80f10113;
        dut.u_CPU.if_id_register.u_IMEM.words[8] = 32'h0020a623;
        dut.u_CPU.if_id_register.u_IMEM.words[9] = 32'h00000113;
        dut.u_CPU.if_id_register.u_IMEM.words[10] = 32'h00c0a103;
        dut.u_CPU.if_id_register.u_IMEM.words[11] = 32'h00100193;
        dut.u_CPU.if_id_register.u_IMEM.words[12] = 32'h0000006f;
        reset_cpu();
        run_normal_case(32'h0015580f, "L3_NORMAL_SW_LW_RAW_HIGH");
        if (dut.u_hex_display.raw_high_reg !== 21'h15580f)
            $fatal(1, "L3_HEX_RAWH_NOT_WRITTEN: raw_high_reg got %h exp 15580f", dut.u_hex_display.raw_high_reg);
        // 21'h15580f = {7'b1010101 (HEX5), 7'b0110000 (HEX4), 7'b0001111 (HEX3)}
        if (HEX3 !== 7'b0001111 || HEX4 !== 7'b0110000 || HEX5 !== 7'b1010101)
            $fatal(1, "L3_RAW_HIGH_PINS_FAIL: HEX3~5 pins mismatch for 0x15580f");
        // Verify HEX0~2 remain completely unaffected by RAW_HIGH write
        if (HEX0 !== 7'b0010010 || HEX1 !== 7'b0100100 || HEX2 !== 7'b1001001)
            $fatal(1, "L3_RAW_HIGH_INTERFERENCE_FAIL: HEX0~2 pins altered by RAW_HIGH write");
        check_step("L3_NORMAL_RAW_HIGH_OUTPUT_CHECK");

        // =========================================================================
        // Step 2: Bridge Access Faults (mcause = 5 / 7) — Unmapped Offsets & Sub-words
        // =========================================================================

        // A. Unmapped Offset Store: sw x2, 16(x1) to 0x4007_0010
        // Expected: mcause = 7 (Store access fault from Bridge), mepc = 8, x2 intact (0x55), HEX state unchanged!
        init_hex_state();
        program_trap_seq(32'h05500113, 32'h0020a823);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd7, 32'h55, 1, 32'h40070010, 3'b010, "L3_TRAP_SW_UNMAPPED_10");

        // B. Unmapped Offset Load: lw x2, 16(x1) from 0x4007_0010
        // Expected: mcause = 5 (Load access fault from Bridge), mepc = 8, x2 protected (remains 0x77)!
        init_hex_state();
        program_trap_seq(32'h07700113, 32'h0100a103);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd5, 32'h77, 1, 32'h40070010, 3'b010, "L3_TRAP_LW_UNMAPPED_10");

        // C. Byte Store to HEX Base: sb x2, 0(x1) to 0x4007_0000
        // Expected: mcause = 7 (Store access fault from Bridge), mepc = 8, x2 intact (0xaa)
        init_hex_state();
        program_trap_seq(32'h0aa00113, 32'h00208023);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd7, 32'haa, 1, 32'h40070000, 3'b000, "L3_TRAP_SB_BRIDGE_FAULT");

        // D. Byte Load from HEX Base: lbu x2, 0(x1) from 0x4007_0000
        // Expected: mcause = 5 (Load access fault from Bridge), mepc = 8, x2 protected (0x33)
        init_hex_state();
        program_trap_seq(32'h03300113, 32'h0000c103);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd5, 32'h33, 1, 32'h40070000, 3'b000, "L3_TRAP_LBU_BRIDGE_FAULT");

        // =========================================================================
        // Step 3: CPU Internal Alignment Faults (mcause = 4 / 6) — Misaligned Word Access
        // =========================================================================

        // A. Misaligned Word Store: sw x2, 1(x1) to 0x4007_0001
        // Expected: mcause = 6 (Store address misaligned, CPU internal, bus suppressed), mepc = 8, x2 intact (0x99)
        init_hex_state();
        program_trap_seq(32'h09900113, 32'h0020a0a3);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd6, 32'h99, 0, 32'h40070001, 3'b010, "L3_TRAP_SW_MISALIGNED");

        // B. Misaligned Word Load: lw x2, 1(x1) from 0x4007_0001
        // Expected: mcause = 4 (Load address misaligned, CPU internal, bus suppressed), mepc = 8, x2 protected (0x44)
        init_hex_state();
        program_trap_seq(32'h04400113, 32'h0010a103);
        reset_cpu();
        init_hex_state();
        run_trap_case(32'd4, 32'h44, 0, 32'h40070001, 3'b010, "L3_TRAP_LW_MISALIGNED");

        $display("SUMMARY: PASS HEX S5 L3 cpu e2e checks=%0d", checks);
        $finish;
    end
endmodule
