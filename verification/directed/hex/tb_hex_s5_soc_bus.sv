`timescale 1ns/1ps
module tb_hex_s5_soc_bus;
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

    reg [31:0] drive_addr = 0, drive_data = 0;
    reg drive_write = 0;
    reg [1:0] drive_trans = 0;
    reg [2:0] drive_size = 3'b010;

    integer checks = 0;
    reg inject_l2_fault = 0;

    reg monitor_active = 0;
    reg [23:0] exp_val = 0;
    reg [1:0]  exp_ctrl = 0;
    reg [20:0] exp_raw_l = 0, exp_raw_h = 0;
    reg [6:0]  exp_h0 = 0, exp_h1 = 0, exp_h2 = 0, exp_h3 = 0, exp_h4 = 0, exp_h5 = 0;

    always #5 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI), .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    // Continuous event-based monitor: instantly detects any register or pin output glitch while monitor_active is 1
    always @(dut.u_hex_display.value_reg or
             dut.u_hex_display.ctrl_reg or
             dut.u_hex_display.raw_low_reg or
             dut.u_hex_display.raw_high_reg or
             HEX0 or HEX1 or HEX2 or HEX3 or HEX4 or HEX5) begin
        if (monitor_active) begin
            if (dut.u_hex_display.value_reg !== exp_val ||
                dut.u_hex_display.ctrl_reg !== exp_ctrl ||
                dut.u_hex_display.raw_low_reg !== exp_raw_l ||
                dut.u_hex_display.raw_high_reg !== exp_raw_h ||
                HEX0 !== exp_h0 || HEX1 !== exp_h1 || HEX2 !== exp_h2 ||
                HEX3 !== exp_h3 || HEX4 !== exp_h4 || HEX5 !== exp_h5) begin
                $fatal(1, "L2_V04_EVENT_GLITCH: register or output glitched while monitor_active! (val=%h, ctrl=%h, exp_ctrl=%h)",
                       dut.u_hex_display.value_reg, dut.u_hex_display.ctrl_reg, exp_ctrl);
            end
        end
    end

    task check_step(input string step_name);
        begin
            checks = checks + 1;
        end
    endtask

    task set_bus(input [31:0] addr, input wr, input [1:0] trans, input [2:0] size);
        begin
            @(negedge clk);
            drive_addr = addr; drive_write = wr; drive_trans = trans; drive_size = size;
            #1;
        end
    endtask

    task write_hex_word(input [31:0] addr, input [31:0] data);
        begin
            drive_data = data;
            set_bus(addr, 1, 2'b10, 3'b010);
            if (!dut.HSEL_APB) $fatal(1, "L2_WRITE_FAIL: HSEL_APB missing for addr=%h", addr);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0080 || dut.PENABLE !== 0 || dut.HREADY !== 0)
                $fatal(1, "L2_WRITE_SETUP_FAIL: addr=%h got PSEL=%h PENABLE=%b HREADY=%b",
                       addr, dut.PSEL, dut.PENABLE, dut.HREADY);
            set_bus(0, 0, 0, 3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0080 || dut.PENABLE !== 1 || dut.HRESP !== 2'b00 || dut.HREADY !== 1)
                $fatal(1, "L2_WRITE_ACCESS_FAIL: addr=%h got PSEL=%h PENABLE=%b HRESP=%b HREADY=%b",
                       addr, dut.PSEL, dut.PENABLE, dut.HRESP, dut.HREADY);
            @(posedge clk); #1;
            check_step("L2_WRITE_HEX");
        end
    endtask

    task read_hex_word(input [31:0] addr, input [31:0] exp_data);
        begin
            set_bus(addr, 0, 2'b10, 3'b010);
            if (!dut.HSEL_APB) $fatal(1, "L2_READ_FAIL: HSEL_APB missing for addr=%h", addr);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0080 || dut.PENABLE !== 0 || dut.HREADY !== 0)
                $fatal(1, "L2_READ_SETUP_FAIL: addr=%h got PSEL=%h PENABLE=%b HREADY=%b",
                       addr, dut.PSEL, dut.PENABLE, dut.HREADY);
            set_bus(0, 0, 0, 3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0080 || dut.PENABLE !== 1 || dut.HRESP !== 2'b00 || dut.HREADY !== 1)
                $fatal(1, "L2_READ_ACCESS_FAIL: addr=%h got PSEL=%h PENABLE=%b HRESP=%b HREADY=%b",
                       addr, dut.PSEL, dut.PENABLE, dut.HRESP, dut.HREADY);
            if (dut.HRDATA !== exp_data)
                $fatal(1, "L2_READ_DATA_FAIL: addr=%h got HRDATA=%h exp=%h", addr, dut.HRDATA, exp_data);
            @(posedge clk); #1;
            check_step("L2_READ_HEX");
        end
    endtask

    // V02 & V04: Monitor entire invalid access interval for PSEL suppression and signal immutability
    task check_hex_error(input [31:0] addr, input wr, input [2:0] size, input [31:0] data, input string check_id);
        reg [23:0] snap_val;
        reg [1:0]  snap_ctrl;
        reg [20:0] snap_raw_low, snap_raw_high;
        reg [6:0]  snap_h0, snap_h1, snap_h2, snap_h3, snap_h4, snap_h5;
        begin
            // 1. Snapshot state before fault and activate event-based monitor
            snap_val      = dut.u_hex_display.value_reg;
            snap_ctrl     = dut.u_hex_display.ctrl_reg;
            snap_raw_low  = dut.u_hex_display.raw_low_reg;
            snap_raw_high = dut.u_hex_display.raw_high_reg;
            snap_h0 = HEX0; snap_h1 = HEX1; snap_h2 = HEX2;
            snap_h3 = HEX3; snap_h4 = HEX4; snap_h5 = HEX5;

            exp_val   = snap_val;
            exp_ctrl  = snap_ctrl;
            exp_raw_l = snap_raw_low;
            exp_raw_h = snap_raw_high;
            exp_h0 = snap_h0; exp_h1 = snap_h1; exp_h2 = snap_h2;
            exp_h3 = snap_h3; exp_h4 = snap_h4; exp_h5 = snap_h5;

            monitor_active = 1;

            drive_data = data;
            set_bus(addr, wr, 2'b10, size);
            if (!dut.HSEL_APB) $fatal(1, "L2_ERR_HSEL_FAIL: %s did not enter APB for addr=%h", check_id, addr);

            // 2. SETUP phase check: PSEL must be 0, outputs/registers unchanged
            @(posedge clk); #1;
            if (inject_l2_fault) begin
                // Injected fault: simulate actual peripheral register corruption on invalid access
                force dut.u_hex_display.ctrl_reg = 2'b00;
            end
            if (dut.PSEL !== 16'h0000 || dut.PENABLE !== 0 || dut.HREADY !== 0)
                $fatal(1, "L2_ERR_SETUP_FAIL: %s — PSEL was not suppressed! got PSEL=%h PENABLE=%b HREADY=%b",
                       check_id, dut.PSEL, dut.PENABLE, dut.HREADY);
            if (dut.u_hex_display.value_reg !== snap_val || dut.u_hex_display.ctrl_reg !== snap_ctrl ||
                dut.u_hex_display.raw_low_reg !== snap_raw_low || dut.u_hex_display.raw_high_reg !== snap_raw_high ||
                HEX0 !== snap_h0 || HEX1 !== snap_h1 || HEX2 !== snap_h2 ||
                HEX3 !== snap_h3 || HEX4 !== snap_h4 || HEX5 !== snap_h5)
                $fatal(1, "L2_V04_SETUP_GLITCH: %s — registers/outputs glitched during SETUP!", check_id);

            set_bus(0, 0, 0, 3'b010);

            // 3. ACCESS phase (Cycle 1 of AHB ERROR): PSEL must stay 0, HRESP=ERROR, HREADY=0
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 0 || dut.PSEL !== 16'h0000)
                $fatal(1, "L2_ERR_CYC1_FAIL: %s — cycle 1 ERROR failed (HRESP=%b, HREADY=%b, PSEL=%h)",
                       check_id, dut.HRESP, dut.HREADY, dut.PSEL);
            if (dut.u_hex_display.value_reg !== snap_val || dut.u_hex_display.ctrl_reg !== snap_ctrl ||
                dut.u_hex_display.raw_low_reg !== snap_raw_low || dut.u_hex_display.raw_high_reg !== snap_raw_high ||
                HEX0 !== snap_h0 || HEX1 !== snap_h1 || HEX2 !== snap_h2 ||
                HEX3 !== snap_h3 || HEX4 !== snap_h4 || HEX5 !== snap_h5)
                $fatal(1, "L2_V04_ACCESS_GLITCH: %s — registers/outputs glitched during ACCESS!", check_id);

            // 4. ERROR_FINAL phase (Cycle 2 of AHB ERROR): HRESP=ERROR, HREADY=1, PSEL=0
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 1 || dut.PSEL !== 16'h0000)
                $fatal(1, "L2_ERR_CYC2_FAIL: %s — cycle 2 ERROR failed (HRESP=%b, HREADY=%b, PSEL=%h)",
                       check_id, dut.HRESP, dut.HREADY, dut.PSEL);
            if (dut.u_hex_display.value_reg !== snap_val || dut.u_hex_display.ctrl_reg !== snap_ctrl ||
                dut.u_hex_display.raw_low_reg !== snap_raw_low || dut.u_hex_display.raw_high_reg !== snap_raw_high ||
                HEX0 !== snap_h0 || HEX1 !== snap_h1 || HEX2 !== snap_h2 ||
                HEX3 !== snap_h3 || HEX4 !== snap_h4 || HEX5 !== snap_h5)
                $fatal(1, "L2_V04_FINAL_GLITCH: %s — registers/outputs glitched during ERROR_FINAL!", check_id);

            // 5. Post-cycle check (IDLE state recovery): HRESP=OKAY, HREADY=1
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b00 || dut.HREADY !== 1)
                $fatal(1, "L2_ERR_RECOVERY_FAIL: %s — failed to recover to OKAY/IDLE", check_id);
            if (dut.u_hex_display.value_reg !== snap_val || dut.u_hex_display.ctrl_reg !== snap_ctrl ||
                dut.u_hex_display.raw_low_reg !== snap_raw_low || dut.u_hex_display.raw_high_reg !== snap_raw_high ||
                HEX0 !== snap_h0 || HEX1 !== snap_h1 || HEX2 !== snap_h2 ||
                HEX3 !== snap_h3 || HEX4 !== snap_h4 || HEX5 !== snap_h5)
                $fatal(1, "L2_V04_POST_MUTATION: %s — state corrupted after invalid transaction!", check_id);

            monitor_active = 0;
            check_step(check_id);
        end
    endtask

    initial begin
        if ($test$plusargs("INJECT_L2_SIDE_EFFECT_FAULT")) begin
            inject_l2_fault = 1;
            $display("[MUTATION] INJECT_L2_SIDE_EFFECT_FAULT enabled");
        end

        // Force CPU AHB bus master wires
        force dut.HADDR = drive_addr;
        force dut.HWRITE = drive_write;
        force dut.HTRANS = drive_trans;
        force dut.HSIZE = drive_size;
        force dut.HWDATA = drive_data;
        force dut.PRESETN_SYS = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        force dut.PRESETN_SYS = 1;
        repeat (4) @(posedge clk);

        // --- Step 1: Verify Initial Reset State of HEX Display ---
        if (dut.u_hex_display.value_reg !== 24'h0 ||
            dut.u_hex_display.ctrl_reg !== 2'b01 ||
            dut.u_hex_display.raw_low_reg !== 21'h1fffff ||
            dut.u_hex_display.raw_high_reg !== 21'h1fffff)
            $fatal(1, "L2_RESET_STATE_FAIL: initial register values incorrect");
        // Decode of 0 is 7'b1000000 on active-low display
        if (HEX0 !== 7'b1000000 || HEX1 !== 7'b1000000 || HEX2 !== 7'b1000000 ||
            HEX3 !== 7'b1000000 || HEX4 !== 7'b1000000 || HEX5 !== 7'b1000000)
            $fatal(1, "L2_RESET_OUTPUT_FAIL: initial decoded outputs are not HEX-0");
        check_step("L2_RESET_CHECK");

        // --- Step 2: V01 Normal R/W & AC-V01 Evaluation ---
        // Write VALUE = 0x00123456
        write_hex_word(32'h40070000, 32'h00123456);
        read_hex_word(32'h40070000, 32'h00123456);
        // Digit 6=1, 5=2, 4=3, 3=4, 2=5, 1=6
        // hex_to_seg(6)=7'b0000010 (HEX0), hex_to_seg(1)=7'b1111001 (HEX5)
        if (HEX0 !== 7'b0000010 || HEX5 !== 7'b1111001)
            $fatal(1, "L2_V01_OUTPUT_VAL_FAIL: outputs did not update to 0x123456");
        check_step("L2_V01_VAL_OK");

        // Test AC-V01: Disable display (ENABLE = 0)
        write_hex_word(32'h40070004, 32'h00000000);
        read_hex_word(32'h40070004, 32'h00000000);
        // When ENABLE=0, all outputs must be BLANK (7'b1111111)
        if (HEX0 !== 7'b1111111 || HEX1 !== 7'b1111111 || HEX2 !== 7'b1111111 ||
            HEX3 !== 7'b1111111 || HEX4 !== 7'b1111111 || HEX5 !== 7'b1111111)
            $fatal(1, "L2_AC_V01_DISABLE_BLANK_FAIL: disabled display did not blank outputs");
        check_step("L2_AC_V01_DISABLE_OK");

        // Write VALUE while disabled: outputs must STAY BLANK! (AC-V01 core requirement)
        write_hex_word(32'h40070000, 32'h00abcdef);
        read_hex_word(32'h40070000, 32'h00abcdef);
        if (HEX0 !== 7'b1111111 || HEX5 !== 7'b1111111)
            $fatal(1, "L2_AC_V01_WRITE_WHILE_DISABLED_FAIL: write while disabled unblanked output!");
        check_step("L2_AC_V01_DISABLED_WRITE_OK");

        // Re-enable in RAW mode (ENABLE=1, RAW_MODE=1) with distinct patterns
        write_hex_word(32'h40070008, 32'h000a5a5a);
        read_hex_word(32'h40070008, 32'h000a5a5a);
        write_hex_word(32'h4007000c, 32'h0005a5a5);
        read_hex_word(32'h4007000c, 32'h0005a5a5);
        write_hex_word(32'h40070004, 32'h00000003); // ENABLE=1, RAW_MODE=1
        read_hex_word(32'h40070004, 32'h00000003);
        if (HEX0 !== 7'b1011010 || HEX3 !== 7'b0100101)
            $fatal(1, "L2_V01_RAW_MODE_FAIL: raw mode outputs did not update");
        check_step("L2_V01_RAW_OK");

        // --- Step 3: V02, V03, V04 Invalid Accesses & Full-Interval Immutability (AC-V04) ---
        // A. Unmapped Offsets within Slot 7
        check_hex_error(32'h40070010, 1, 3'b010, 32'hdeadbeef, "L2_V04_UNMAPPED_10_WR");
        check_hex_error(32'h40070010, 0, 3'b010, 32'h00000000, "L2_V04_UNMAPPED_10_RD");
        check_hex_error(32'h40070014, 1, 3'b010, 32'hdeadbeef, "L2_V04_UNMAPPED_14_WR");
        check_hex_error(32'h40070100, 1, 3'b010, 32'hdeadbeef, "L2_V04_UNMAPPED_100_WR");
        check_hex_error(32'h4007fffc, 1, 3'b010, 32'hdeadbeef, "L2_V04_UNMAPPED_FFFC_WR");

        // B. Sub-word accesses on canonical base
        check_hex_error(32'h40070000, 1, 3'b000, 32'h00000055, "L2_V04_BYTE_WR_VAL");
        check_hex_error(32'h40070004, 1, 3'b000, 32'h00000000, "L2_V04_BYTE_WR_CTRL");
        check_hex_error(32'h40070008, 1, 3'b001, 32'h0000ffff, "L2_V04_HALF_WR_RAWL");
        check_hex_error(32'h4007000c, 1, 3'b000, 32'h000000aa, "L2_V04_BYTE_WR_RAWH");

        // C. Misaligned accesses on canonical base
        check_hex_error(32'h40070001, 1, 3'b010, 32'hbaadf00d, "L2_V04_MISALIGN_01_WR");
        check_hex_error(32'h40070002, 1, 3'b010, 32'hbaadf00d, "L2_V04_MISALIGN_02_WR");

        // --- Step 4: Normal Transaction Recovery after Faults ---
        read_hex_word(32'h40070008, 32'h000a5a5a);
        read_hex_word(32'h4007000c, 32'h0005a5a5);
        write_hex_word(32'h40070004, 32'h00000001); // restore decoder mode
        read_hex_word(32'h40070004, 32'h00000001);

        $display("SUMMARY: PASS HEX S5 L2 soc bus checks=%0d", checks);
        $finish;
    end
endmodule
