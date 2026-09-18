`timescale 1ns/1ps

module tb_p08b_vga_cpu_fault;
    reg clk = 0;
    reg [1:0] key = 2'b11;
    reg [9:0] sw = 0;
    reg [2:1] gs_int = 0;
    reg gs_sdo = 0, lora_rx = 1, lora_aux = 0, uart_rx = 1;
    wire [9:0] ledr;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;
    wire gs_cs, gs_clk, gs_sdi;
    wire [3:0] vr, vg, vb;
    wire vhs, vvs, lora_tx, uart_tx;

    reg [31:0] main_pc;
    reg [31:0] trap_pc;
    reg [31:0] loop_pc;
    reg [8*512-1:0] imem_hex;
    integer cycles;
    integer error_wait_cycles = 0;
    integer error_final_cycles = 0;
    integer fail_stop_cycles = 0;
    integer physical_writes_during_error = 0;
    reg main_seen = 0;
    reg handler_seen = 0;
    reg marker_seen = 0;
    reg fault_store_seen = 0;
    reg retry_seen = 0;
    reg fault_completed = 0;

    always #5 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(key), .SW(sw), .LEDR(ledr),
        .GPIO_IO(),
        .HEX0(hex0), .HEX1(hex1), .HEX2(hex2), .HEX3(hex3),
        .HEX4(hex4), .HEX5(hex5),
        .G_SENSOR_CS_N(gs_cs), .G_SENSOR_INT(gs_int),
        .G_SENSOR_SCLK(gs_clk), .G_SENSOR_SDI(gs_sdi), .G_SENSOR_SDO(gs_sdo),
        .VGA_R(vr), .VGA_G(vg), .VGA_B(vb), .VGA_HS(vhs), .VGA_VS(vvs),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    always @(posedge clk) begin
        if (dut.HRESETn) begin
            if (dut.u_CPU.ID_valid && dut.u_CPU.ID_pc == main_pc)
                main_seen = 1;
            if (dut.HSEL_VRAM_d && dut.HRESP == 2'b01 && !dut.HREADY)
                error_wait_cycles = error_wait_cycles + 1;
            if (dut.HSEL_VRAM_d && dut.HRESP == 2'b01 && dut.HREADY) begin
                error_final_cycles = error_final_cycles + 1;
                fault_completed = 1;
            end
            if (dut.HSEL_VRAM && dut.HWRITE && dut.HADDR == 32'h2000_9600)
                fault_store_seen = 1;
            if (fault_completed && dut.HSEL_VRAM && dut.HWRITE &&
                dut.HADDR == 32'h2000_9600)
                retry_seen = 1;
            if (dut.U_VRAM.vram0_we || dut.U_VRAM.vram1_we) begin
                if (dut.HRESP == 2'b01)
                    physical_writes_during_error = physical_writes_during_error + 1;
            end
            if (dut.u_CPU.ID_valid && dut.u_CPU.ID_pc == trap_pc)
                handler_seen = 1;
            if (handler_seen && dut.u_CPU.register_file.registers[7] == 32'h54524150)
                marker_seen = 1;
            if (marker_seen && dut.u_CPU.pc == loop_pc)
                fail_stop_cycles = fail_stop_cycles + 1;
        end
    end

    initial begin
        if (!$value$plusargs("IMEM_HEX=%s", imem_hex) ||
            !$value$plusargs("MAIN_PC=%h", main_pc) ||
            !$value$plusargs("TRAP_PC=%h", trap_pc) ||
            !$value$plusargs("LOOP_PC=%h", loop_pc))
            $fatal(1, "required plusargs missing");

        force dut.PRESETN_SYS = 1'b0;
        #1;
        $readmemh(imem_hex, dut.u_CPU.if_id_register.u_IMEM.words);
        // Preserve the built startup and handler. Replace only main's first
        // instructions with a store to the VGA-owned canonical gap.
        dut.u_CPU.if_id_register.u_IMEM.words[main_pc[13:2] + 0] = 32'h2000_90b7;
        dut.u_CPU.if_id_register.u_IMEM.words[main_pc[13:2] + 1] = 32'h6000_8093;
        dut.u_CPU.if_id_register.u_IMEM.words[main_pc[13:2] + 2] = 32'h0550_0113;
        dut.u_CPU.if_id_register.u_IMEM.words[main_pc[13:2] + 3] = 32'h0020_a023;
        dut.u_CPU.if_id_register.u_IMEM.words[main_pc[13:2] + 4] = 32'h0010_0193;

        repeat (5) @(posedge clk);
        @(negedge clk);
        force dut.PRESETN_SYS = 1'b1;

        begin : wait_handler
            for (cycles = 0; cycles < 30000; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (marker_seen) disable wait_handler;
            end
            $fatal(1, "integrated VGA fault handler timeout pc=%h", dut.u_CPU.pc);
        end

        repeat (100) @(posedge clk);
        #1;
        if (!main_seen || !fault_store_seen)
            $fatal(1, "main/VGA store absent main=%0d store=%0d cause=%h mepc=%h pc=%h",
                   main_seen, fault_store_seen, dut.u_CPU.csr_file.mcause,
                   dut.u_CPU.csr_file.mepc, dut.u_CPU.pc);
        if (error_wait_cycles != 1 || error_final_cycles != 1)
            $fatal(1, "VGA ERROR timing wait=%0d final=%0d",
                   error_wait_cycles, error_final_cycles);
        if (physical_writes_during_error != 0)
            $fatal(1, "VRAM WE occurred during rejected store");
        if (dut.u_CPU.csr_file.mcause !== 32'd7 ||
            dut.u_CPU.csr_file.mepc !== main_pc + 32'd12)
            $fatal(1, "fault CSR cause=%h mepc=%h",
                   dut.u_CPU.csr_file.mcause, dut.u_CPU.csr_file.mepc);
        if (dut.u_CPU.register_file.registers[5] !== 32'd7 ||
            dut.u_CPU.register_file.registers[6] !== main_pc + 32'd12 ||
            dut.u_CPU.register_file.registers[7] !== 32'h54524150)
            $fatal(1, "handler diagnostic registers incorrect");
        if (dut.u_CPU.register_file.registers[3] !== 32'd0)
            $fatal(1, "younger instruction committed");
        if (retry_seen || fail_stop_cycles < 20)
            $fatal(1, "retry or unstable fail-stop retry=%0d cycles=%0d",
                   retry_seen, fail_stop_cycles);

        $display("SUMMARY: PASS P08B actual VGA ERROR to CPU fail-stop");
        $finish;
    end
endmodule
