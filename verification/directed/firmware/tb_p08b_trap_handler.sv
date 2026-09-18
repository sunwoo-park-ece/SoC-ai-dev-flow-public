`timescale 1ns/1ps

// P08B Gate 0 positive verification using a generated firmware image.
// CASE=0: normal boot; CASE=1: post-startup store ERROR; CASE=2: illegal
// instruction injected at main in the otherwise unchanged generated image.
module tb_p08b_trap_handler;
    reg clk = 1'b0;
    reg reset = 1'b1;
    wire [31:0] HADDR, HWDATA, HRDATA;
    wire HWRITE, bus_stall_req;
    wire [1:0] HTRANS, HRESP;
    wire [2:0] HSIZE, HBURST;
    wire [3:0] write_mask, mask_out;
    wire ex_read, ex_write, bram_hazard;
    wire [31:0] ex_addr, store_data, read_data, retire_instruction;
    wire [2:0] ex_funct3;
    wire HREADY;

    integer test_case;
    integer cycles;
    integer redirect_count = 0;
    integer fault_final_count = 0;
    integer transfer_count_after_fault = 0;
    integer fail_stop_cycles = 0;
    reg [1:0] response_state = 2'd0;
    reg [31:0] main_pc;
    reg [31:0] trap_pc;
    reg [31:0] loop_pc;
    reg [31:0] fault_pc = 32'hffff_ffff;
    reg main_seen = 1'b0;
    reg fault_requested = 1'b0;
    reg fault_final_seen = 1'b0;
    reg handler_seen = 1'b0;
    reg marker_seen = 1'b0;
    reg younger_commit_seen = 1'b0;
    reg fault_retire_seen = 1'b0;
    reg application_resume_seen = 1'b0;
    reg retry_seen = 1'b0;
    reg [8*512-1:0] imem_hex;

    always #5 clk = ~clk;

    assign HRDATA = 32'b0;
    assign HREADY = (response_state != 2'd1);
    assign HRESP = (response_state == 2'd0) ? 2'b00 : 2'b01;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            response_state <= 2'd0;
            fault_requested <= 1'b0;
            fault_pc <= 32'hffff_ffff;
        end else if (test_case == 1) begin
            case (response_state)
                2'd0: begin
                    if (main_seen && !fault_requested && HTRANS[1] && HWRITE) begin
                        fault_requested <= 1'b1;
                        fault_pc <= dut.EX_pc;
                        response_state <= 2'd1;
                    end
                end
                2'd1: response_state <= 2'd2;
                2'd2: response_state <= 2'd0;
                default: response_state <= 2'd0;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (dut.ID_valid && dut.ID_pc == main_pc)
                main_seen = 1'b1;
            if (dut.bus_fault_final) begin
                fault_final_count = fault_final_count + 1;
                fault_final_seen = 1'b1;
            end
            if (fault_final_seen && !dut.bus_fault_final && HTRANS[1]) begin
                transfer_count_after_fault = transfer_count_after_fault + 1;
                if (HWRITE && HADDR == ex_addr)
                    retry_seen = 1'b1;
            end
            if (fault_requested && dut.commit_valid && dut.WB_pc == fault_pc)
                fault_retire_seen = 1'b1;
            if (fault_final_seen && !handler_seen && dut.commit_valid &&
                dut.WB_pc > fault_pc)
                younger_commit_seen = 1'b1;
            if (dut.trap_redirect_fire) begin
                redirect_count = redirect_count + 1;
                if (dut.trap_target !== trap_pc)
                    $fatal(1, "trap target=%h expected=%h", dut.trap_target, trap_pc);
            end
            if (dut.ID_valid && dut.ID_pc == trap_pc)
                handler_seen = 1'b1;
            if (handler_seen && dut.register_file.registers[7] == 32'h54524150)
                marker_seen = 1'b1;
            if (marker_seen && dut.commit_valid &&
                dut.WB_pc != trap_pc && dut.WB_pc != trap_pc + 4 &&
                dut.WB_pc != trap_pc + 8 && dut.WB_pc != trap_pc + 12 &&
                dut.WB_pc != loop_pc)
                application_resume_seen = 1'b1;
            if (marker_seen && dut.pc == loop_pc)
                fail_stop_cycles = fail_stop_cycles + 1;
        end
    end

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(1'b1), .reset(reset),
        .retire_instruction(retire_instruction),
        .debug_X1(), .debug_X2(), .debug_X3(), .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(ex_read), .EX_memory_write_AHB(ex_write),
        .EX_alu_result_AHB(ex_addr), .EX_funct3_AHB(ex_funct3),
        .data_memory_read_data_AHB(store_data),
        .HRDATA_FROM_AHB(read_data), .HRESP_FROM_AHB(HRESP),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(bus_stall_req),
        .CUSTOM_WRITE_MASK(write_mask), .oBRAM_HAZARD(bram_hazard)
    );

    AHB_Master_Interface master (
        .EX_memory_read(ex_read), .EX_memory_write(ex_write),
        .EX_alu_result(ex_addr), .EX_funct3(ex_funct3),
        .MEM_read_data2(store_data), .HRDATA_to_CPU(read_data),
        .bus_stall_req(bus_stall_req), .HADDR(HADDR), .HWRITE(HWRITE),
        .HTRANS(HTRANS), .HSIZE(HSIZE), .HBURST(HBURST),
        .HWDATA(HWDATA), .HRDATA(HRDATA), .HREADY(HREADY),
        .CUSTOM_WRITE_MASK_IN(write_mask), .CUSTOM_WRITE_MASK_OUT(mask_out)
    );

    task wait_for_marker;
        begin : wait_block
            for (cycles = 0; cycles < 12000; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (marker_seen)
                    disable wait_block;
            end
            $fatal(1, "handler marker timeout case=%0d pc=%h", test_case, dut.pc);
        end
    endtask

    task prove_fail_stop;
        input [31:0] expected_cause;
        input [31:0] expected_mepc;
        begin
            if (dut.csr_file.mcause !== expected_cause ||
                dut.csr_file.mepc !== expected_mepc)
                $fatal(1, "trap CSR mismatch cause=%0d/%0d mepc=%h/%h",
                       dut.csr_file.mcause, expected_cause,
                       dut.csr_file.mepc, expected_mepc);
            if (dut.register_file.registers[5] !== expected_cause ||
                dut.register_file.registers[6] !== expected_mepc ||
                dut.register_file.registers[7] !== 32'h54524150)
                $fatal(1, "handler diagnostics x5=%h x6=%h x7=%h",
                       dut.register_file.registers[5],
                       dut.register_file.registers[6],
                       dut.register_file.registers[7]);
            repeat (80) @(posedge clk);
            #1;
            if (redirect_count != 1)
                $fatal(1, "trap storm detected redirects=%0d", redirect_count);
            if (fail_stop_cycles < 20)
                $fatal(1, "explicit fail-stop loop was not stably observed cycles=%0d",
                       fail_stop_cycles);
            if (application_resume_seen)
                $fatal(1, "application execution resumed after fail-stop entry");
            if (dut.mret_redirect_fire)
                $fatal(1, "mret redirect observed from fail-stop handler");
        end
    endtask

    initial begin
        if (!$value$plusargs("CASE=%d", test_case) ||
            !$value$plusargs("IMEM_HEX=%s", imem_hex) ||
            !$value$plusargs("MAIN_PC=%h", main_pc) ||
            !$value$plusargs("TRAP_PC=%h", trap_pc) ||
            !$value$plusargs("LOOP_PC=%h", loop_pc))
            $fatal(1, "required plusargs: CASE IMEM_HEX MAIN_PC TRAP_PC LOOP_PC");

        #1;
        $readmemh(imem_hex, dut.if_id_register.u_IMEM.words);
        if (test_case == 2)
            dut.if_id_register.u_IMEM.words[main_pc[13:2]] = 32'h00000000;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        if (test_case == 0) begin : normal_boot
            for (cycles = 0; cycles < 12000; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (main_seen) begin
                    if (dut.csr_file.mtvec !== trap_pc)
                        $fatal(1, "main reached with mtvec=%h expected=%h",
                               dut.csr_file.mtvec, trap_pc);
                    if (redirect_count != 0)
                        $fatal(1, "normal boot trapped redirects=%0d", redirect_count);
                    $display("TEST_A: PASS normal boot mtvec=%h main=%h", trap_pc, main_pc);
                    $display("SUMMARY: PASS P08B firmware trap handler case 0");
                    $finish;
                end
            end
            $fatal(1, "normal boot did not reach main pc=%h", dut.pc);
        end else if (test_case == 1) begin
            wait_for_marker();
            prove_fail_stop(32'd7, fault_pc);
            if (!main_seen || !fault_requested || fault_final_count != 1)
                $fatal(1, "store injection incomplete main=%0d request=%0d final=%0d",
                       main_seen, fault_requested, fault_final_count);
            if (fault_retire_seen || younger_commit_seen)
                $fatal(1, "precise fault failure retire=%0d younger=%0d",
                       fault_retire_seen, younger_commit_seen);
            if (retry_seen || transfer_count_after_fault != 0)
                $fatal(1, "bus activity after final fault transfers=%0d retry=%0d",
                       transfer_count_after_fault, retry_seen);
            $display("TEST_B: PASS store fault pc=%h cause=7 fail-stop=%h",
                     fault_pc, loop_pc);
            $display("SUMMARY: PASS P08B firmware trap handler case 1");
            $finish;
        end else if (test_case == 2) begin
            wait_for_marker();
            prove_fail_stop(32'd2, main_pc);
            if (fault_final_count != 0)
                $fatal(1, "illegal-instruction case unexpectedly used bus fault");
            $display("TEST_C: PASS illegal instruction pc=%h cause=2 fail-stop=%h",
                     main_pc, loop_pc);
            $display("SUMMARY: PASS P08B firmware trap handler case 2");
            $finish;
        end else begin
            $fatal(1, "unknown CASE=%0d", test_case);
        end
    end
endmodule
