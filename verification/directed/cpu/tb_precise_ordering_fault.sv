`timescale 1ns/1ps
// 3B2A G-M: fault age, WB ownership, one-shot trap service, stale-q rejection.
module tb_precise_ordering_fault;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, clk_enable = 1, error_mode = 0;
    wire [31:0] HADDR, HWDATA, HRDATA;
    wire HWRITE, bus_stall_req;
    wire [1:0] HTRANS, HRESP;
    wire [2:0] HSIZE, HBURST;
    wire [3:0] write_mask, mask_out;
    wire ex_read, ex_write, bram_hazard, HREADY;
    wire [31:0] ex_addr, store_data, read_data, retire_instruction;
    wire [2:0] ex_funct3;
    reg [1:0] response_state = 0;
    integer i, cycles, mepc_writes, mcause_writes, mtvec_reads;
    integer trap_consumes, redirects, fault_wb_cycles, fault_final_count;
    reg [31:0] expected_pc, expected_cause;
    reg [3:0] expected_project_cause;
    reg saw_older_wb, saw_fault_wb, saw_younger_kill;
    reg check_after_redirect;
    reg [31:0] held_wb_instruction;
    reg [3:0] held_wb_cause;
    // 3B2B: score only the pre-trap architectural stream. The handler is
    // deliberately outside each fault program's expected sequence.
    integer commit_count, expected_count;
    reg [31:0] expected_commit_pc [0:7];
    reg [31:0] expected_commit_insn [0:7];
    reg scoreboard_active;
    reg [63:0] minstret_before;
    reg sampled_commit;

    assign HRDATA = 32'd19;
    assign HREADY = response_state != 2'd1;
    assign HRESP = error_mode && response_state != 0 ? 2'b01 : 2'b00;
    always @(posedge clk or posedge reset) begin
        if (reset) response_state <= 0;
        else if (clk_enable) case (response_state)
            0: if (HTRANS[1]) response_state <= 1;
            1: response_state <= 2;
            2: response_state <= 0;
            default: response_state <= 0;
        endcase
    end

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
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

    always @(posedge clk) if (!reset) begin
        minstret_before = dut.csr_file.minstret;
        sampled_commit = dut.commit_valid;
        if (sampled_commit) begin
            if (!dut.WB_valid || dut.WB_exc_valid || dut.MEM_WB_stall ||
                dut.MEM_WB_flush || dut.wb_is_mret)
                $fatal(1, "3B2B fault-suite commit without successful WB owner");
            if (scoreboard_active) begin
                if (commit_count >= expected_count ||
                    dut.WB_pc !== expected_commit_pc[commit_count] ||
                    dut.WB_instruction !== expected_commit_insn[commit_count])
                    $fatal(1, "3B2B fault scoreboard[%0d] PC=%h insn=%h expected=%h/%h",
                           commit_count, dut.WB_pc, dut.WB_instruction,
                           expected_commit_pc[commit_count],
                           expected_commit_insn[commit_count]);
                commit_count = commit_count + 1;
            end
        end
        if (dut.gpr_commit && !sampled_commit ||
            dut.normal_csr_write && !sampled_commit ||
            dut.trap_wr_valid && dut.normal_csr_write)
            $fatal(1, "3B2B fault-suite side-effect ownership violation");
        if ((!dut.EX_valid && (ex_read || ex_write || dut.EX_exc_valid)) ||
            (!dut.MEM_valid && dut.MEM_exc_valid) ||
            (!dut.WB_valid && (dut.WB_exc_valid || dut.wb_owner_release ||
                               dut.normal_csr_write)))
            $fatal(1, "invalid stage asserted a stage-owned side effect/exception");
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h341)
            mepc_writes = mepc_writes + 1;
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h342)
            mcause_writes = mcause_writes + 1;
        if (dut.trap_req_valid && dut.trap_req_addr == 12'h305)
            mtvec_reads = mtvec_reads + 1;
        if (dut.trap_rsp_consume) trap_consumes = trap_consumes + 1;
        if (dut.trap_redirect_fire) begin
            if (scoreboard_active && commit_count != expected_count)
                $fatal(1, "3B2B pre-trap count %0d/%0d",
                       commit_count, expected_count);
            scoreboard_active = 0;
            redirects = redirects + 1;
            check_after_redirect = 1;
        end
        if (dut.bus_fault_final) begin
            fault_final_count = fault_final_count + 1;
            if (ex_read || ex_write || dut.EX_memory_read_AHB ||
                dut.EX_memory_write_AHB)
                $fatal(1, "younger EX bus address accepted on MEM ERROR");
            if (dut.WB_valid && dut.WB_pc < dut.MEM_pc)
                saw_older_wb = 1;
        end
        if (dut.WB_valid && dut.WB_exc_valid) begin
            if (dut.commit_valid || dut.gpr_commit || dut.normal_csr_write)
                $fatal(1, "3B2B fault token retired or wrote architectural state");
            fault_wb_cycles = fault_wb_cycles + 1;
            saw_fault_wb = 1;
            if (dut.WB_pc !== expected_pc ||
                dut.WB_exc_cause !== expected_project_cause ||
                dut.WB_register_write_enable ||
                dut.WB_csr_write_enable || dut.wb_owner_release)
                $fatal(1, "fault WB token identity or side-effect isolation failed");
        end
        if (dut.fault_pending && !dut.ID_valid && !dut.EX_valid)
            saw_younger_kill = 1;
        if (!clk_enable && (dut.trap_wr_valid || dut.trap_req_valid ||
                            dut.trap_rsp_consume || dut.trap_redirect_fire))
            $fatal(1, "trap service repeated during clk_enable hold");
        #1;
        if (dut.csr_file.minstret !== minstret_before + sampled_commit)
            $fatal(1, "3B2B fault-suite minstret delta mismatch");
    end

    task prepare(input [31:0] pc, input [31:0] cause);
        begin
            @(negedge clk); reset = 1; clk_enable = 1; error_mode = 0;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = 32'b0;
            for (i = 0; i < 64; i = i + 1)
                dut.if_id_register.u_IMEM.words[i] = 32'h00000013;
            dut.if_id_register.u_IMEM.words[12'hB58] = 32'h00700393; // trap vector
            expected_pc = pc; expected_cause = cause;
            case (cause)
                32'd11: expected_project_cause = 4'd2;
                32'd4: expected_project_cause = 4'd7;
                32'd5: expected_project_cause = 4'd8;
                32'd7: expected_project_cause = 4'd9;
                default: expected_project_cause = 4'd0;
            endcase
            mepc_writes = 0; mcause_writes = 0; mtvec_reads = 0;
            trap_consumes = 0; redirects = 0; fault_wb_cycles = 0;
            fault_final_count = 0; saw_older_wb = 0;
            saw_fault_wb = 0; saw_younger_kill = 0;
            check_after_redirect = 0;
            commit_count = 0; expected_count = 0; scoreboard_active = 0;
            repeat (3) @(posedge clk);
        end
    endtask
    task launch;
        begin @(negedge clk); reset = 0; scoreboard_active = 1; end
    endtask
    task expect_commit(input integer idx, input [31:0] pc,
                       input [31:0] insn);
        begin
            expected_commit_pc[idx] = pc;
            expected_commit_insn[idx] = insn;
            expected_count = idx + 1;
        end
    endtask
    task wait_service;
        begin : wait_block
            for (cycles = 0; cycles < 90; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (redirects == 1) disable wait_block;
            end
            $fatal(1, "fault service timeout pc=%h cause=%0d state=%0d",
                   expected_pc, expected_cause, dut.trap_controller.state);
        end
    endtask
    task check_service;
        begin
            if (mepc_writes != 1 || mcause_writes != 1 ||
                mtvec_reads != 1 || trap_consumes != 1 || redirects != 1 ||
                !saw_fault_wb || !saw_younger_kill ||
                dut.csr_file.mepc !== expected_pc ||
                dut.csr_file.mcause !== expected_cause)
                $fatal(1, "fault service/age mismatch writes=%0d/%0d read=%0d consume=%0d redirect=%0d wb=%0d kill=%0d mepc=%h mcause=%h",
                    mepc_writes, mcause_writes, mtvec_reads, trap_consumes,
                    redirects, saw_fault_wb, saw_younger_kill,
                    dut.csr_file.mepc, dut.csr_file.mcause);
        end
    endtask
    task check_stale_q;
        begin : stale_block
            for (cycles = 0; cycles < 8; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (dut.ID_valid) begin
                    if (dut.ID_pc !== 32'h00006d60 ||
                        dut.ID_instruction !== 32'h00700393)
                        $fatal(1, "stale IMEM q re-entered after trap redirect pc=%h insn=%h",
                               dut.ID_pc, dut.ID_instruction);
                    disable stale_block;
                end
            end
            $fatal(1, "trap target token absent after redirect");
        end
    endtask

    initial begin
        #1;
        // G/J/M: ID ECALL, three older ALU tokens, one younger token.
        prepare(32'd12, 32'd11);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h00200113;
        dut.if_id_register.u_IMEM.words[2] = 32'h00300193;
        dut.if_id_register.u_IMEM.words[3] = 32'h00000073;
        dut.if_id_register.u_IMEM.words[4] = 32'h00900293;
        expect_commit(0, 0, 32'h00100093);
        expect_commit(1, 4, 32'h00200113);
        expect_commit(2, 8, 32'h00300193);
        launch(); wait_service(); check_service(); check_stale_q();
        repeat (4) @(posedge clk); #1;
        if (dut.register_file.registers[1] !== 1 ||
            dut.register_file.registers[2] !== 2 ||
            dut.register_file.registers[3] !== 3 ||
            dut.register_file.registers[5] !== 0 ||
            dut.register_file.registers[7] !== 7)
            $fatal(1, "ID fault age/target GPR mismatch");
        if (dut.WB_exc_valid || redirects != 1)
            $fatal(1, "fault WB token was not cleared exactly once");
        $display("PASS G/J/M ID fault, WB service, stale q");

        // H: EX misaligned load; older MEM/WB survive, younger is killed.
        prepare(32'd12, 32'd4);
        dut.if_id_register.u_IMEM.words[0] = 32'h100000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00200113;
        dut.if_id_register.u_IMEM.words[2] = 32'h00300193;
        dut.if_id_register.u_IMEM.words[3] = 32'h0010A203; // lw x4,1(x1)
        dut.if_id_register.u_IMEM.words[4] = 32'h00900293;
        expect_commit(0, 0, 32'h100000B7);
        expect_commit(1, 4, 32'h00200113);
        expect_commit(2, 8, 32'h00300193);
        launch(); wait_service(); check_service();
        if (dut.register_file.registers[2] !== 2 ||
            dut.register_file.registers[3] !== 3 ||
            dut.register_file.registers[4] !== 0 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "EX fault age/GPR mismatch");
        $display("PASS H EX fault age");

        // I/J: final AHB ERROR while an older WB and younger EX store exist.
        prepare(32'd8, 32'd5);
        error_mode = 1;
        dut.if_id_register.u_IMEM.words[0] = 32'h500000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[2] = 32'h0000A183; // lw x3,0(x1)
        dut.if_id_register.u_IMEM.words[3] = 32'h0020A023; // younger sw
        dut.if_id_register.u_IMEM.words[4] = 32'h00900293;
        expect_commit(0, 0, 32'h500000B7);
        expect_commit(1, 4, 32'h00700113);
        launch(); wait_service(); check_service();
        if (!saw_older_wb || fault_final_count != 1 ||
            dut.register_file.registers[2] !== 7 ||
            dut.register_file.registers[3] !== 0 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "MEM ERROR age/older WB mismatch older=%0d finals=%0d x2=%h x3=%h x5=%h",
                   saw_older_wb, fault_final_count,
                   dut.register_file.registers[2],
                   dut.register_file.registers[3],
                   dut.register_file.registers[5]);
        $display("PASS I/J MEM final ERROR + older WB");

        // 3B2B H/I: failed store is serviced, never committed; older WB
        // still retires on the final ERROR completion edge.
        prepare(32'd8, 32'd7);
        error_mode = 1;
        dut.if_id_register.u_IMEM.words[0] = 32'h500000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[2] = 32'h0020A023;
        dut.if_id_register.u_IMEM.words[3] = 32'h00900293;
        expect_commit(0, 0, 32'h500000B7);
        expect_commit(1, 4, 32'h00700113);
        launch(); wait_service(); check_service();
        if (!saw_older_wb || fault_final_count != 1 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "failed store/older WB commit mismatch");
        $display("PASS 3B2B failed store and older WB commit");

        // K: interrupt the WB service clock after fault token arrives.
        prepare(32'd4, 32'd11);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000073;
        expect_commit(0, 0, 32'h00100093);
        launch();
        begin : wait_mepe
            for (cycles = 0; cycles < 35; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.trap_controller.state == 4'd1) disable wait_mepe;
            end
            $fatal(1, "WB fault service never reached mepc state");
        end
        clk_enable = 0;
        held_wb_instruction = dut.WB_instruction;
        held_wb_cause = dut.WB_exc_cause;
        repeat (4) @(posedge clk); #1;
        if (mepc_writes || mcause_writes || mtvec_reads || redirects ||
            !dut.WB_valid || !dut.WB_exc_valid || dut.WB_pc != 4 ||
            dut.WB_instruction !== held_wb_instruction ||
            dut.WB_exc_cause !== held_wb_cause)
            $fatal(1, "clk_enable hold did not preserve fault owner");
        @(negedge clk); clk_enable = 1;
        begin : wait_trap_response
            for (cycles = 0; cycles < 35; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.trap_controller.state == 4'd4 &&
                    dut.csr_rsp_valid && dut.csr_rsp_owner == 2'b10)
                    disable wait_trap_response;
            end
            $fatal(1, "trap mtvec response never became owned and valid");
        end
        clk_enable = 0;
        repeat (3) @(posedge clk); #1;
        if (!dut.csr_rsp_valid || dut.csr_rsp_owner != 2'b10 ||
            dut.csr_read_out !== 32'h00006d60 ||
            mepc_writes != 1 || mcause_writes != 1 ||
            mtvec_reads != 1 || trap_consumes || redirects)
            $fatal(1, "held trap CSR response changed/duplicated");
        @(negedge clk); clk_enable = 1;
        wait_service(); check_service();
        $display("PASS K WB service clock interruption");
        $display("SUMMARY: PASS 3B2A fault ordering G-M");
        $finish;
    end
endmodule
