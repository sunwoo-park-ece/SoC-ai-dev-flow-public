`timescale 1ns/1ps
// Live instruction stream and AHB response timing; no CPU token is forced.
module tb_trap_precision_interaction;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, clk_enable = 1, HREADY = 1;
    reg [1:0] HRESP = 0;
    wire [31:0] HADDR, HWDATA, read_data, store_data, ex_addr;
    wire HWRITE, bus_stall_req, ex_read, ex_write;
    wire [1:0] HTRANS;
    wire [2:0] HSIZE, HBURST, ex_funct3;
    wire [3:0] write_mask, mask_out;
    integer i, cycles, commits, expected_commits;
    integer mepc_writes, mcause_writes, mtvec_reqs, mtvec_consumes;
    integer trap_redirects, fault_clears, fault_wb_cycles;
    integer store_accepts, normal_csr_writes;
    integer normal_csr_reqs;
    integer tick, last_older_commit_cycle, first_csr_req_cycle;
    reg [31:0] expected_pc, expected_cause;
    reg [31:0] commit_pc [0:3], commit_insn [0:3];
    reg scoreboard_on, saw_wait, saw_error, saw_csr_hold, saw_bubble;
    reg sampled_redirect;
    reg [63:0] minstret_before;
    reg sampled_commit;

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .retire_instruction(), .debug_X1(), .debug_X2(), .debug_X3(),
        .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(ex_read), .EX_memory_write_AHB(ex_write),
        .EX_alu_result_AHB(ex_addr), .EX_funct3_AHB(ex_funct3),
        .data_memory_read_data_AHB(store_data),
        .HRDATA_FROM_AHB(read_data), .HRESP_FROM_AHB(HRESP),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(bus_stall_req),
        .CUSTOM_WRITE_MASK(write_mask), .oBRAM_HAZARD()
    );
    AHB_Master_Interface master (
        .EX_memory_read(ex_read), .EX_memory_write(ex_write),
        .EX_alu_result(ex_addr), .EX_funct3(ex_funct3),
        .MEM_read_data2(store_data), .HRDATA_to_CPU(read_data),
        .bus_stall_req(bus_stall_req), .HADDR(HADDR), .HWRITE(HWRITE),
        .HTRANS(HTRANS), .HSIZE(HSIZE), .HBURST(HBURST),
        .HWDATA(HWDATA), .HRDATA(32'd19), .HREADY(HREADY),
        .CUSTOM_WRITE_MASK_IN(write_mask), .CUSTOM_WRITE_MASK_OUT(mask_out)
    );

    always @(posedge clk) if (!reset) begin
        tick = tick + 1;
        minstret_before = dut.csr_file.minstret;
        sampled_commit = dut.commit_valid;
        sampled_redirect = dut.trap_redirect_fire && !dut.mret_redirect_fire;
        if (dut.gpr_commit && !sampled_commit ||
            dut.normal_csr_write && !sampled_commit ||
            dut.trap_wr_valid && dut.normal_csr_write)
            $fatal(1, "normal/trap writer ownership violation");
        if (dut.WB_valid && dut.WB_exc_valid) begin
            fault_wb_cycles = fault_wb_cycles + 1;
            if (dut.commit_valid || dut.gpr_commit ||
                dut.normal_csr_write || dut.WB_pc !== expected_pc)
                $fatal(1, "fault WB retired or lost PC owner");
        end
        if (sampled_commit && scoreboard_on) begin
            if (commits >= expected_commits ||
                dut.WB_pc !== commit_pc[commits] ||
                dut.WB_instruction !== commit_insn[commits])
                $fatal(1, "older commit rank=%0d got PC=%h insn=%h",
                       commits, dut.WB_pc, dut.WB_instruction);
            commits = commits + 1;
            if (dut.WB_pc < 8) last_older_commit_cycle = tick;
        end
        if (dut.normal_csr_write) normal_csr_writes = normal_csr_writes + 1;
        if (dut.normal_csr_req) begin
            normal_csr_reqs = normal_csr_reqs + 1;
            if (first_csr_req_cycle < 0) first_csr_req_cycle = tick;
        end
        if (dut.csr_front_hold && dut.ID_valid) saw_csr_hold = 1;
        if (dut.ID_EX_flush && dut.ID_valid &&
            dut.ID_pc == 4 && dut.EX_valid &&
            dut.EX_memory_read) saw_bubble = 1;
        if (HTRANS[1] && HREADY && HWRITE)
            store_accepts = store_accepts + 1;
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h341) begin
            mepc_writes = mepc_writes + 1;
            if (dut.trap_wr_data !== expected_pc)
                $fatal(1, "mepc wrong PC got=%h expected=%h",
                       dut.trap_wr_data, expected_pc);
        end
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h342) begin
            mcause_writes = mcause_writes + 1;
            if (dut.trap_wr_data !== expected_cause)
                $fatal(1, "mcause wrong cause got=%h expected=%h",
                       dut.trap_wr_data, expected_cause);
        end
        if (dut.trap_req_valid && dut.trap_req_addr == 12'h305)
            mtvec_reqs = mtvec_reqs + 1;
        if (dut.trap_rsp_consume) mtvec_consumes = mtvec_consumes + 1;
        if (dut.bus_fault_final) saw_error = 1;
        if (sampled_redirect) begin
            if (!dut.WB_valid || !dut.WB_exc_valid)
                $fatal(1, "trap redirect lacked fault WB owner");
            if (commits != expected_commits)
                $fatal(1, "older commit count=%0d expected=%0d",
                       commits, expected_commits);
            trap_redirects = trap_redirects + 1;
            scoreboard_on = 0;
        end
        #1;
        if (sampled_redirect) begin
            if (dut.WB_exc_valid)
                $fatal(1, "fault WB token did not clear on redirect");
            fault_clears = fault_clears + 1;
        end
        if (dut.csr_file.minstret !== minstret_before + sampled_commit)
            $fatal(1, "minstret delta mismatch");
    end

    task prepare(input [31:0] pc, input [31:0] cause);
        begin
            @(negedge clk); reset = 1; clk_enable = 1;
            HREADY = 1; HRESP = 0; scoreboard_on = 0;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = 0;
            for (i = 0; i < 64; i = i + 1)
                dut.if_id_register.u_IMEM.words[i] = 32'h00000013;
            dut.if_id_register.u_IMEM.words[12'hB58] = 32'h00700393;
            expected_pc = pc; expected_cause = cause;
            commits = 0; expected_commits = 0;
            mepc_writes = 0; mcause_writes = 0;
            mtvec_reqs = 0; mtvec_consumes = 0;
            trap_redirects = 0; fault_clears = 0; fault_wb_cycles = 0;
            store_accepts = 0; normal_csr_writes = 0;
            normal_csr_reqs = 0;
            tick = 0; last_older_commit_cycle = -1;
            first_csr_req_cycle = -1;
            saw_wait = 0; saw_error = 0;
            saw_csr_hold = 0; saw_bubble = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    task expect_commit(input integer rank, input [31:0] pc,
                       input [31:0] insn);
        begin
            commit_pc[rank] = pc;
            commit_insn[rank] = insn;
            expected_commits = rank + 1;
        end
    endtask
    task launch;
        begin @(negedge clk); reset = 0; scoreboard_on = 1; end
    endtask
    task wait_trap;
        begin : waiting
            for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
                @(negedge clk);
                if (trap_redirects == 1) disable waiting;
            end
            $fatal(1, "trap timeout expected PC=%h cause=%h",
                   expected_pc, expected_cause);
        end
    endtask
    task check_trap;
        begin
            if (commits != expected_commits ||
                mepc_writes != 1 || mcause_writes != 1 ||
                mtvec_reqs != 1 || mtvec_consumes != 1 ||
                trap_redirects != 1 || fault_clears != 1 ||
                fault_wb_cycles == 0 ||
                normal_csr_writes != 0 ||
                dut.csr_file.mepc !== expected_pc ||
                dut.csr_file.mcause !== expected_cause)
                $fatal(1, "service mismatch commits=%0d/%0d mepc=%0d mcause=%0d mtvec=%0d/%0d redirect=%0d",
                       commits, expected_commits, mepc_writes, mcause_writes,
                       mtvec_reqs, mtvec_consumes, trap_redirects);
            begin : target_wait
                for (cycles = 0; cycles < 8; cycles = cycles + 1) begin
                    @(posedge clk); #1;
                    if (dut.ID_valid) begin
                        if (dut.ID_pc !== 32'h00006d60 ||
                            dut.ID_instruction !== 32'h00700393)
                            $fatal(1, "stale fetch after trap redirect PC=%h insn=%h",
                                   dut.ID_pc, dut.ID_instruction);
                        disable target_wait;
                    end
                end
                $fatal(1, "trap target fetch token absent");
            end
        end
    endtask
    task wait_commits(input integer target);
        begin : waiting
            for (cycles = 0; cycles < 80; cycles = cycles + 1) begin
                @(negedge clk);
                if (commits == target) disable waiting;
            end
            $fatal(1, "commit timeout got=%0d target=%0d", commits, target);
        end
    endtask
    task hold_mem(input [31:0] mem_pc, input [31:0] younger_pc,
                  input bit younger_is_id);
        reg [31:0] old_mem, old_ex, old_id, old_haddr;
        reg [1:0] old_htrans;
        reg old_hwrite;
        begin
            begin : waiting
                for (cycles = 0; cycles < 40; cycles = cycles + 1) begin
                    @(negedge clk);
                    if (dut.MEM_valid && dut.MEM_pc == mem_pc &&
                        (younger_is_id ? (dut.ID_valid && dut.ID_pc == younger_pc) :
                                         (dut.EX_valid && dut.EX_pc == younger_pc)))
                        disable waiting;
                end
                $fatal(1, "MEM+younger alignment absent MEM=%h EX=%h ID=%h",
                       dut.MEM_pc, dut.EX_pc, dut.ID_pc);
            end
            HREADY = 0;
            old_mem = dut.MEM_pc; old_ex = dut.EX_pc; old_id = dut.ID_pc;
            old_haddr = HADDR; old_htrans = HTRANS; old_hwrite = HWRITE;
            repeat (3) begin
                @(posedge clk); #1;
                if (!bus_stall_req || !dut.MEM_valid ||
                    dut.MEM_pc !== old_mem || dut.EX_pc !== old_ex ||
                    dut.ID_pc !== old_id || HADDR !== old_haddr ||
                    HTRANS !== old_htrans || HWRITE !== old_hwrite ||
                    dut.commit_valid || dut.trap_redirect_fire ||
                    dut.trap_wr_valid || dut.trap_req_valid)
                    $fatal(1, "AHB wait lost token/bus identity");
                saw_wait = 1;
            end
            @(negedge clk); HREADY = 1;
        end
    endtask

    initial begin
        #1;
        // A: ID illegal held behind older MEM load.
        prepare(8, 2);
        dut.register_file.registers[1] = 32'h10000000;
        dut.if_id_register.u_IMEM.words[0] = 32'h0000A103;
        dut.if_id_register.u_IMEM.words[1] = 32'h00100193;
        dut.if_id_register.u_IMEM.words[2] = 32'h00000000;
        dut.if_id_register.u_IMEM.words[3] = 32'h00900293;
        expect_commit(0, 0, 32'h0000A103);
        expect_commit(1, 4, 32'h00100193);
        launch(); hold_mem(0, 8, 1); wait_trap(); check_trap();
        if (!saw_wait || dut.register_file.registers[2] !== 19 ||
            dut.register_file.registers[3] !== 1 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "A older load/younger side effect mismatch");
        $display("PASS A ID illegal + older MEM AHB wait");

        // B: EX JAL target misalignment behind older MEM load.
        prepare(8, 0);
        dut.if_id_register.u_IMEM.words[0] = 32'h100000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h0000A103;
        dut.if_id_register.u_IMEM.words[2] = 32'h0020016F;
        dut.if_id_register.u_IMEM.words[3] = 32'h00900293;
        expect_commit(0, 0, 32'h100000B7);
        expect_commit(1, 4, 32'h0000A103);
        launch(); hold_mem(4, 8, 0); wait_trap(); check_trap();
        if (!saw_wait || dut.register_file.registers[2] !== 19 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "B older load/EX fault side effect mismatch");
        $display("PASS B EX fault + older MEM AHB wait");

        // C: older WB, MEM final ERROR, younger EX store and ID illegal.
        prepare(8, 5);
        dut.if_id_register.u_IMEM.words[0] = 32'h500000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[2] = 32'h0000A183;
        dut.if_id_register.u_IMEM.words[3] = 32'h0020A023;
        dut.if_id_register.u_IMEM.words[4] = 32'h00000000;
        expect_commit(0, 0, 32'h500000B7);
        expect_commit(1, 4, 32'h00700113);
        launch();
        begin : waiting_c
            for (cycles = 0; cycles < 40; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.MEM_valid && dut.MEM_pc == 8 &&
                    dut.EX_valid && dut.EX_pc == 12 &&
                    dut.ID_valid && dut.ID_pc == 16)
                    disable waiting_c;
            end
            $fatal(1, "C four-level age stack absent");
        end
        HREADY = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); HREADY = 1; HRESP = 2'b01;
        @(posedge clk);
        if (!dut.bus_fault_final || !dut.commit_valid ||
            dut.WB_pc !== 4 || ex_read || ex_write || HTRANS[1])
            $fatal(1, "C final ERROR failed older WB/younger kill");
        @(negedge clk); HRESP = 0;
        wait_trap(); check_trap();
        if (!saw_error || store_accepts != 0 ||
            dut.register_file.registers[2] !== 7 ||
            dut.register_file.registers[3] !== 0)
            $fatal(1, "C final ERROR side effect mismatch");
        $display("PASS C MEM ERROR + older WB + younger EX/ID");

        // D/I: a held younger CSR must be killed by older EX redirect.
        prepare(0, 0);
        dut.if_id_register.u_IMEM.words[0] = 32'h0080006F; // jal +8
        dut.if_id_register.u_IMEM.words[1] = 32'hB02021F3; // killed CSR
        dut.if_id_register.u_IMEM.words[2] = 32'h00500293; // target
        expect_commit(0, 0, 32'h0080006F);
        expect_commit(1, 8, 32'h00500293);
        launch(); wait_commits(2); scoreboard_on = 0;
        if (normal_csr_reqs || normal_csr_writes ||
            trap_redirects || dut.register_file.registers[5] !== 5)
            $fatal(1, "D younger CSR survived older redirect");
        $display("PASS D younger CSR candidate killed by older EX redirect");

        // E/J: older EX target fault cancels a held younger CSR owner.
        prepare(0, 0);
        dut.if_id_register.u_IMEM.words[0] = 32'h0020006F; // jal +2, cause 0
        dut.if_id_register.u_IMEM.words[1] = 32'hB02021F3; // killed CSR
        launch(); wait_trap(); check_trap();
        if (normal_csr_reqs || normal_csr_writes)
            $fatal(1, "E younger CSR issued after older EX fault");
        $display("PASS E younger CSR candidate killed by older EX fault");

        // E-equivalent: a genuinely held CSR DRAIN owner is cancelled by
        // an older MEM final ERROR. EX fault/redirect wins before CSR first
        // acquisition, so it cannot coexist with an already-held CSR.
        prepare(0, 5);
        dut.register_file.registers[1] = 32'h50000000;
        dut.if_id_register.u_IMEM.words[0] = 32'h0000A103; // older lw
        dut.if_id_register.u_IMEM.words[1] = 32'hB02021F3; // held CSR
        launch();
        begin : waiting_held_csr
            for (cycles = 0; cycles < 30; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.MEM_valid && dut.MEM_pc == 0 &&
                    dut.ID_valid && dut.ID_pc == 4 &&
                    dut.serial_state == 2'd1)
                    disable waiting_held_csr;
            end
            $fatal(1, "E-equivalent held CSR with older MEM absent");
        end
        HRESP = 2'b01;
        @(posedge clk);
        if (!dut.bus_fault_final)
            $fatal(1, "E-equivalent older MEM final ERROR absent");
        @(negedge clk); HRESP = 0;
        wait_trap(); check_trap();
        if (!saw_csr_hold || normal_csr_reqs || normal_csr_writes)
            $fatal(1, "E-equivalent held CSR survived older MEM fault");
        $display("PASS E-equivalent held CSR cancelled by older MEM fault");

        // F: real load-use invalid bubble preceding a valid ECALL fault.
        prepare(8, 11);
        dut.register_file.registers[1] = 32'h10000000;
        dut.if_id_register.u_IMEM.words[0] = 32'h0000A103; // lw x2,0(x1)
        dut.if_id_register.u_IMEM.words[1] = 32'h00110193; // addi x3,x2,1
        dut.if_id_register.u_IMEM.words[2] = 32'h00000073; // ecall
        expect_commit(0, 0, 32'h0000A103);
        expect_commit(1, 4, 32'h00110193);
        launch(); wait_trap(); check_trap();
        if (!saw_bubble || dut.register_file.registers[2] !== 19 ||
            dut.register_file.registers[3] !== 20)
            $fatal(1, "F load-use bubble or older commit mismatch");
        $display("PASS F load-use invalid bubble + ECALL");

        // K: older MEM final ERROR wins over younger EX JAL misalignment.
        prepare(0, 5);
        dut.register_file.registers[1] = 32'h50000000;
        dut.if_id_register.u_IMEM.words[0] = 32'h0000A103; // lw x2,0(x1)
        dut.if_id_register.u_IMEM.words[1] = 32'h0020006F; // younger +2 fault
        dut.if_id_register.u_IMEM.words[2] = 32'h00000073; // youngest ECALL
        launch();
        begin : waiting_k
            for (cycles = 0; cycles < 40; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.MEM_valid && dut.MEM_pc == 0 &&
                    dut.EX_valid && dut.EX_pc == 4 &&
                    dut.ID_valid && dut.ID_pc == 8)
                    disable waiting_k;
            end
            $fatal(1, "K MEM/EX/ID age stack absent");
        end
        HRESP = 2'b01;
        @(posedge clk);
        if (!dut.bus_fault_final || !dut.EX_fault_raw)
            $fatal(1, "K competing MEM/EX fault not present");
        @(negedge clk); HRESP = 0;
        wait_trap(); check_trap();
        if (!saw_error || dut.register_file.registers[2] !== 0)
            $fatal(1, "K failed load side effect");
        $display("PASS K MEM final ERROR wins over EX/ID faults");

        // L: CSR request is not issued on the last older WB commit edge.
        // D/E above cover decisive older redirect/fault cancellation.
        prepare(0, 0);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093; // older ALU
        dut.if_id_register.u_IMEM.words[1] = 32'h00200113; // older ALU
        dut.if_id_register.u_IMEM.words[2] = 32'hB02021F3; // CSR read minstret
        expect_commit(0, 0, 32'h00100093);
        expect_commit(1, 4, 32'h00200113);
        expect_commit(2, 8, 32'hB02021F3);
        launch(); wait_commits(3); scoreboard_on = 0;
        if (!saw_csr_hold || normal_csr_reqs != 1 ||
            first_csr_req_cycle <= last_older_commit_cycle ||
            dut.register_file.registers[1] !== 1 ||
            dut.register_file.registers[2] !== 2 ||
            dut.register_file.registers[3] !== 2)
            $fatal(1, "L CSR drain-boundary request or older retirement wrong");
        $display("PASS L CSR request after last older commit boundary");

        $display("SUMMARY: PASS TRAP-002 interaction A/B/C/D/E/E-equivalent/F/K/L");
        $finish;
    end
endmodule
