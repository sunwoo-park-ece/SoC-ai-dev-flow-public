`timescale 1ns/1ps
module tb_trap_isa_closure;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, clk_enable = 1;
    wire ex_read, ex_write;
    wire [31:0] ex_addr;
    integer i, cycles, pattern_idx, commits, mret_commits;
    integer mepc_writes, mcause_writes, normal_mepc_writes, mret_reads;
    integer trap_reads, trap_redirects, mret_redirects, bus_requests;
    integer normal_csr_requests;
    reg [31:0] expected_cause, expected_pc;
    reg check_trap;
    reg [63:0] count_before;
    reg sampled_commit;
    reg saw_jalr_redirect;
    reg [31:0] observed_jalr_target;
    reg scoreboard_enable;
    reg check_mepc_write;
    reg [31:0] expected_mepc_after_write;
    reg [31:0] expected_commit_pc [0:7];
    reg [31:0] expected_commit_insn [0:7];

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .retire_instruction(), .debug_X1(), .debug_X2(), .debug_X3(),
        .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(ex_read), .EX_memory_write_AHB(ex_write),
        .EX_alu_result_AHB(ex_addr), .EX_funct3_AHB(),
        .data_memory_read_data_AHB(), .HRDATA_FROM_AHB(32'd0),
        .HRESP_FROM_AHB(2'b00), .HREADY_FROM_AHB(1'b1),
        .bus_stall_req(1'b0), .CUSTOM_WRITE_MASK(), .oBRAM_HAZARD()
    );

    always @(posedge clk) if (!reset) begin
        count_before = dut.csr_file.minstret;
        sampled_commit = dut.commit_valid;
        check_mepc_write = 0;
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h341) begin
            check_mepc_write = 1;
            expected_mepc_after_write = {dut.trap_wr_data[31:2], 2'b00};
        end else if (dut.normal_csr_write &&
                     dut.WB_raw_imm[11:0] == 12'h341) begin
            check_mepc_write = 1;
            expected_mepc_after_write = {dut.WB_alu_result[31:2], 2'b00};
            normal_mepc_writes = normal_mepc_writes + 1;
        end
        if (dut.WB_exc_valid &&
            (dut.commit_valid || dut.gpr_commit || dut.normal_csr_write))
            $fatal(1, "faulting WB token produced normal architectural effect");
        if (dut.trap_wr_valid && dut.normal_csr_write)
            $fatal(1, "trap and normal CSR writers overlap");
        if (dut.gpr_commit && !dut.commit_valid)
            $fatal(1, "GPR write without commit");
        if (dut.normal_csr_write && !dut.commit_valid)
            $fatal(1, "normal CSR write without commit");
        if (ex_read || ex_write) bus_requests = bus_requests + 1;
        if (dut.normal_csr_req) normal_csr_requests = normal_csr_requests + 1;
        if (dut.mret_req_valid) mret_reads = mret_reads + 1;
        if (dut.EX_valid && dut.EX_jump &&
            dut.EX_opcode == 7'h67 && !dut.ex_fault_now &&
            !dut.EX_exc_valid && !dut.mem_fault_now) begin
            saw_jalr_redirect = 1;
            observed_jalr_target = dut.next_pc;
        end
        if (dut.commit_valid) begin
            if (scoreboard_enable &&
                (dut.WB_pc !== expected_commit_pc[commits] ||
                 dut.WB_instruction !== expected_commit_insn[commits]))
                $fatal(1, "commit scoreboard[%0d] got %h/%h expected %h/%h",
                       commits, dut.WB_pc, dut.WB_instruction,
                       expected_commit_pc[commits],
                       expected_commit_insn[commits]);
            commits = commits + 1;
            if (dut.wb_is_mret) begin
                mret_commits = mret_commits + 1;
                if (!dut.mret_redirect_fire || dut.gpr_commit ||
                    dut.normal_csr_write || dut.WB_instruction !== 32'h30200073)
                    $fatal(1, "MRET retirement did not own redirect edge");
            end
        end
        if (dut.trap_wr_valid) begin
            if (dut.trap_wr_addr == 12'h341) begin
                mepc_writes = mepc_writes + 1;
                if (check_trap && dut.trap_wr_data !== expected_pc)
                    $fatal(1, "mepc write PC=%h expected=%h",
                           dut.trap_wr_data, expected_pc);
            end
            if (dut.trap_wr_addr == 12'h342) begin
                mcause_writes = mcause_writes + 1;
                if (check_trap && dut.trap_wr_data !== expected_cause)
                    $fatal(1, "mcause write cause=%h expected=%h",
                           dut.trap_wr_data, expected_cause);
            end
        end
        if (dut.trap_req_valid) trap_reads = trap_reads + 1;
        if (dut.trap_redirect_fire) begin
            if (dut.mret_redirect_fire) begin
                if (dut.trap_target[1:0] !== 2'b00 ||
                    dut.trap_target !== dut.csr_file.mepc ||
                    dut.WB_exc_valid || !dut.commit_valid)
                    $fatal(1, "MRET target/canonical ownership failure");
                mret_redirects = mret_redirects + 1;
            end else trap_redirects = trap_redirects + 1;
        end
        #1;
        if (dut.csr_file.mepc[1:0] !== 2'b00 ||
            (check_mepc_write &&
             dut.csr_file.mepc !== expected_mepc_after_write))
            $fatal(1, "mepc storage is not canonical expected=%h got=%h",
                   expected_mepc_after_write, dut.csr_file.mepc);
        if (dut.csr_file.minstret !== count_before + sampled_commit)
            $fatal(1, "minstret delta mismatch");
    end

    task prepare;
        begin
            scoreboard_enable = 0;
            check_trap = 0;
            @(negedge clk); reset = 1; clk_enable = 1; check_trap = 0;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = 32'b0;
            for (i = 0; i < 64; i = i + 1)
                dut.if_id_register.u_IMEM.words[i] = 32'h00000013;
            dut.if_id_register.u_IMEM.words[12'hB58] = 32'h00700393;
            commits = 0; mret_commits = 0; mepc_writes = 0;
            mcause_writes = 0; trap_reads = 0; trap_redirects = 0;
            normal_mepc_writes = 0; mret_reads = 0;
            mret_redirects = 0; bus_requests = 0;
            normal_csr_requests = 0;
            saw_jalr_redirect = 0; observed_jalr_target = 0;
            scoreboard_enable = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    task launch;
        begin @(negedge clk); reset = 0; end
    endtask
    task expect_commit(input integer idx, input [31:0] pc,
                       input [31:0] insn);
        begin
            expected_commit_pc[idx] = pc;
            expected_commit_insn[idx] = insn;
            scoreboard_enable = 1;
        end
    endtask
    task wait_for_trap;
        begin : waiting
            for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
                @(negedge clk);
                if (trap_redirects == 1) disable waiting;
            end
            $fatal(1, "trap timeout insn=%h", dut.if_id_register.u_IMEM.words[0]);
        end
    endtask
    task wait_for_commits(input integer target);
        begin : waiting
            for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
                @(negedge clk);
                if (commits >= target) disable waiting;
            end
            $fatal(1, "commit timeout count=%0d target=%0d", commits, target);
        end
    endtask
    task fault_case(input [31:0] insn, input [31:0] cause,
                    input [31:0] rs1_value, input bit no_bus);
        begin
            prepare();
            dut.register_file.registers[1] = rs1_value;
            dut.if_id_register.u_IMEM.words[0] = insn;
            dut.if_id_register.u_IMEM.words[1] = 32'h00900293;
            expected_pc = 0; expected_cause = cause; check_trap = 1;
            launch(); wait_for_trap();
            if (commits != 0 || mepc_writes != 1 || mcause_writes != 1 ||
                trap_reads != 1 || trap_redirects != 1 ||
                dut.csr_file.mepc !== 0 || dut.csr_file.mcause !== cause ||
                dut.register_file.registers[5] !== 0)
                $fatal(1, "trap scoreboard mismatch insn=%h cause=%0d commits=%0d mepc=%h mcause=%h",
                       insn, cause, commits, dut.csr_file.mepc,
                       dut.csr_file.mcause);
            if (no_bus && bus_requests != 0)
                $fatal(1, "pre-bus fault requested AHB insn=%h", insn);
            $display("PASS trap insn=%h cause=%0d no_bus=%0d", insn, cause, no_bus);
        end
    endtask
    task retire_case(input [31:0] insn, input [31:0] rs1_value,
                     input [31:0] expected_rd_value, input bit check_rd);
        begin
            prepare();
            dut.register_file.registers[1] = rs1_value;
            dut.if_id_register.u_IMEM.words[0] = insn;
            expect_commit(0, 0, insn);
            launch(); wait_for_commits(1);
            if (trap_redirects || mepc_writes || mcause_writes ||
                dut.csr_file.minstret !== 1 ||
                (check_rd && dut.register_file.registers[2] !== expected_rd_value))
                $fatal(1, "legal retire mismatch insn=%h rd=%h expected=%h",
                       insn, dut.register_file.registers[2], expected_rd_value);
            $display("PASS retire insn=%h", insn);
        end
    endtask
    task shift_case(input [31:0] insn, input [31:0] source,
                    input [31:0] shamt, input [31:0] expected);
        begin
            prepare();
            dut.register_file.registers[1] = source;
            dut.register_file.registers[2] = shamt;
            dut.if_id_register.u_IMEM.words[0] = insn;
            expect_commit(0, 0, insn);
            launch(); wait_for_commits(1);
            if (dut.register_file.registers[3] !== expected)
                $fatal(1, "shift mismatch insn=%h source=%h rs2=%h got=%h expected=%h",
                       insn, source, shamt,
                       dut.register_file.registers[3], expected);
        end
    endtask
    task counter_case(input [11:0] addr);
        reg [31:0] insn;
        begin
            insn = {addr, 5'd1, 3'b001, 5'd2, 7'h73};
            prepare();
            dut.register_file.registers[1] = 32'hDEADBEEF;
            dut.if_id_register.u_IMEM.words[0] = insn;
            expect_commit(0, 0, insn);
            launch(); wait_for_commits(1);
            if (trap_redirects || normal_csr_requests != 1 ||
                dut.register_file.registers[2] === 32'hDEADBEEF ||
                dut.csr_file.mcycle[31:0] === 32'hDEADBEEF ||
                dut.csr_file.mcycle[63:32] === 32'hDEADBEEF ||
                dut.csr_file.minstret !== 1)
                $fatal(1, "counter write-ignore failed addr=%h", addr);
            $display("PASS counter write-ignore addr=%h", addr);
        end
    endtask
    task canonical_mepc_case(input [31:0] written_value);
        reg [31:0] canonical_value;
        begin
            canonical_value = {written_value[31:2], 2'b00};
            prepare();
            dut.register_file.registers[1] = written_value;
            dut.if_id_register.u_IMEM.words[0] = 32'h34109073; // csrrw x0,mepc,x1
            dut.if_id_register.u_IMEM.words[1] = 32'h341021F3; // csrrs x3,mepc,x0
            dut.if_id_register.u_IMEM.words[2] = 32'h30200073; // mret
            dut.if_id_register.u_IMEM.words[3] = 32'h00000000; // killed fallthrough
            dut.if_id_register.u_IMEM.words[4] = 32'h00700113; // resumed
            expect_commit(0, 0, 32'h34109073);
            expect_commit(1, 4, 32'h341021F3);
            expect_commit(2, 8, 32'h30200073);
            expect_commit(3, 16, 32'h00700113);
            launch(); wait_for_commits(2);
            if (dut.register_file.registers[3] !== canonical_value ||
                dut.csr_file.mepc !== canonical_value ||
                normal_mepc_writes != 1 || normal_csr_requests != 1 ||
                trap_redirects || mepc_writes || mcause_writes)
                $fatal(1, "mepc CSR canonical readback failed raw=%h read=%h stored=%h",
                       written_value, dut.register_file.registers[3],
                       dut.csr_file.mepc);
            wait_for_commits(3);
            if (mret_commits != 1 || mret_redirects != 1 ||
                mret_reads != 1 || dut.pc !== canonical_value ||
                dut.csr_file.minstret !== 3 || trap_redirects)
                $fatal(1, "MRET canonical redirect failed raw=%h pc=%h",
                       written_value, dut.pc);
            begin : first_resumed_id
                for (cycles = 0; cycles < 12; cycles = cycles + 1) begin
                    @(negedge clk);
                    if (dut.ID_valid) begin
                        if (dut.ID_pc !== canonical_value ||
                            dut.ID_instruction !== 32'h00700113)
                            $fatal(1, "stale fetch after MRET raw=%h id=%h/%h",
                                   written_value, dut.ID_pc, dut.ID_instruction);
                        disable first_resumed_id;
                    end
                end
                $fatal(1, "first resumed ID token absent raw=%h", written_value);
            end
            wait_for_commits(4);
            if (dut.register_file.registers[2] !== 7 ||
                dut.csr_file.minstret !== 4 || mret_commits != 1 ||
                mret_redirects != 1 || trap_redirects || mcause_writes)
                $fatal(1, "canonical MRET resume/retirement failed raw=%h",
                       written_value);
            $display("PASS mepc write/read/MRET raw=%h canonical=%h",
                     written_value, canonical_value);
        end
    endtask

    initial begin
        #1;
        for (pattern_idx = 0; pattern_idx < 4; pattern_idx = pattern_idx + 1)
            canonical_mepc_case(32'h00000010 + pattern_idx);
        // Verify upper bits without redirecting into an unmapped test image.
        prepare();
        dut.register_file.registers[1] = 32'h1234567B;
        dut.if_id_register.u_IMEM.words[0] = 32'h34109073;
        dut.if_id_register.u_IMEM.words[1] = 32'h341021F3;
        expect_commit(0, 0, 32'h34109073);
        expect_commit(1, 4, 32'h341021F3);
        launch(); wait_for_commits(2);
        if (dut.csr_file.mepc !== 32'h12345678 ||
            dut.register_file.registers[3] !== 32'h12345678 ||
            normal_mepc_writes != 1 || trap_redirects)
            $fatal(1, "mepc upper-address canonicalization failure");
        $display("PASS mepc upper-address write/read canonicalization");

        // ID-owned exact SYSTEM, invalid opcode/funct3/funct7/shift/CSR.
        fault_case(32'h00000073, 11, 0, 1); // ECALL
        fault_case(32'h00100073, 3, 0, 1);  // EBREAK
        fault_case(32'h00108073, 2, 0, 1);  // noncanonical EBREAK
        fault_case(32'h30208073, 2, 0, 1);  // noncanonical MRET
        fault_case(32'h00000000, 2, 0, 1);  // unsupported opcode
        fault_case(32'h000090E7, 2, 0, 1);  // JALR funct3
        fault_case(32'h020000B3, 2, 0, 1);  // unsupported R funct7
        fault_case(32'h02001093, 2, 0, 1);  // unsupported SLLI upper
        fault_case(32'h777020F3, 2, 0, 1);  // unsupported CSR address
        fault_case(32'h305040F3, 2, 0, 1);  // unsupported CSR funct3
        fault_case(32'hF11091F3, 2, 1, 1);  // write to fixed mvendorid
        fault_case(32'h00003083, 2, 0, 1);  // unsupported LOAD funct3
        fault_case(32'h00103023, 2, 0, 1);  // unsupported STORE funct3

        // EX-owned address and target alignment.
        fault_case(32'h0000A103, 4, 1, 1);  // LW x2,0(x1), x1=1
        fault_case(32'h0020A023, 6, 1, 1);  // SW x2,0(x1), x1=1
        fault_case(32'h00000163, 0, 0, 1);  // taken BEQ +2
        fault_case(32'h0020016F, 0, 0, 1);  // JAL x2,+2
        fault_case(32'h00008167, 0, 32'h13, 1); // JALR x2,0(x1), raw=0x13

        // Not-taken branch's nominal +2 target must not fault.
        retire_case(32'h00008163, 1, 0, 0);
        // FENCE/FENCE.I legal no-ops.
        retire_case(32'h0000000F, 0, 0, 0);
        retire_case(32'h0000100F, 0, 0, 0);
        // Machine IDs and counter write-ignore.
        retire_case(32'hF1102173, 0, 0, 1);
        retire_case(32'hF1202173, 0, 0, 1);
        retire_case(32'hF1302173, 0, 32'h00010000, 1);
        retire_case(32'hF1402173, 0, 0, 1);
        counter_case(12'hB00);
        counter_case(12'hB80);
        counter_case(12'hB02);
        counter_case(12'hB82);
        retire_case(32'h30500113, 0, 32'h305, 1);
        if (normal_csr_requests != 0)
            $fatal(1, "non-SYSTEM CSR-looking immediate issued a CSR read");
        shift_case(32'h002091B3, 1, 0, 1);
        shift_case(32'h002091B3, 1, 31, 32'h80000000);
        shift_case(32'h002091B3, 1, 32, 1);
        shift_case(32'h002091B3, 1, 33, 2);
        shift_case(32'h002091B3, 1, 63, 32'h80000000);
        shift_case(32'h002091B3, 1, 32'hFFFF_FFFF, 32'h80000000);
        shift_case(32'h0020D1B3, 32'h80000000, 33, 32'h40000000);
        shift_case(32'h0020D1B3, 32'h80000000, 32'hFFFF_FFFF, 1);
        shift_case(32'h4020D1B3, 32'h80000000, 33, 32'hC0000000);
        shift_case(32'h4020D1B3, 32'h80000000, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        $display("PASS register shift amount masking and SLL/SRL/SRA");

        // Older redirect kills younger ID illegal instruction.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h0080006F;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000000;
        dut.if_id_register.u_IMEM.words[2] = 32'h00700113;
        expect_commit(0, 0, 32'h0080006F);
        expect_commit(1, 8, 32'h00700113);
        launch(); wait_for_commits(2);
        if (trap_redirects || dut.register_file.registers[2] !== 7)
            $fatal(1, "older EX redirect lost priority over ID illegal");
        $display("PASS older EX redirect > younger ID illegal");

        // Older EX target fault dominates younger ID ECALL.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00000163;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000073;
        expected_pc = 0; expected_cause = 0; check_trap = 1;
        launch(); wait_for_trap();
        if (commits || dut.csr_file.mcause !== 0 ||
            dut.csr_file.mepc !== 0)
            $fatal(1, "older EX fault lost priority over ID ECALL");
        $display("PASS older EX fault > younger ID ECALL");

        // Older MEM load retires before a younger EX branch-target fault.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00002103;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000163;
        dut.if_id_register.u_IMEM.words[2] = 32'h00000073;
        expect_commit(0, 0, 32'h00002103);
        expected_pc = 4; expected_cause = 0; check_trap = 1;
        launch(); wait_for_trap();
        if (commits != 1 || dut.csr_file.mepc !== 4 ||
            dut.csr_file.mcause !== 0 || dut.csr_file.minstret !== 1)
            $fatal(1, "older MEM commit/younger EX fault ordering failed");
        $display("PASS older MEM commit + EX target fault + younger ID kill");

        // Odd raw target 0x11 is cleared to 0x10 and remains legal.
        prepare();
        dut.register_file.registers[1] = 32'h11;
        dut.if_id_register.u_IMEM.words[0] = 32'h00008167;
        dut.if_id_register.u_IMEM.words[4] = 32'h00700393;
        expect_commit(0, 0, 32'h00008167);
        launch(); wait_for_commits(1);
        if (dut.register_file.registers[2] !== 4 ||
            !saw_jalr_redirect || observed_jalr_target !== 32'h10 ||
            trap_redirects || dut.csr_file.minstret !== 1)
            $fatal(1, "JALR bit0-clear redirect/link failure target=%h",
                   observed_jalr_target);
        $display("PASS JALR raw odd target masked and retired");

        // MRET uses exact mepc and commits once on its service redirect edge.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h30200073;
        dut.if_id_register.u_IMEM.words[4] = 32'h00700113;
        expect_commit(0, 0, 32'h30200073);
        expect_commit(1, 16, 32'h00700113);
        launch();
        @(negedge clk); dut.csr_file.mepc = 32'h10;
        begin : wait_mret_response
            for (cycles = 0; cycles < 50; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.trap_controller.state == 4'd7 &&
                    dut.csr_rsp_valid && dut.csr_rsp_owner == 2'b11)
                    disable wait_mret_response;
            end
            $fatal(1, "MRET owner-tagged response timeout");
        end
        clk_enable = 0;
        repeat (3) begin
            @(negedge clk);
            if (commits || mret_redirects || dut.mret_redirect_fire ||
                dut.commit_valid || !dut.csr_rsp_valid ||
                dut.csr_rsp_owner != 2'b11)
                $fatal(1, "MRET hold duplicated or lost response");
        end
        clk_enable = 1;
        wait_for_commits(1);
        if (mret_commits != 1 || mret_redirects != 1 ||
            dut.pc !== 32'h10 || dut.csr_file.minstret !== 1 ||
            dut.normal_csr_write || dut.gpr_commit)
            $fatal(1, "MRET exact target/one-shot commit failure pc=%h", dut.pc);
        wait_for_commits(2);
        if (dut.register_file.registers[2] !== 7 ||
            dut.csr_file.minstret !== 2 || mret_commits != 1 ||
            mret_redirects != 1)
            $fatal(1, "MRET resumed instruction/count failure");
        $display("PASS MRET exact mepc, one-shot retirement, resumed token");

        // Fault -> handler CSR update -> MRET -> resumed instruction.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00000073;
        dut.if_id_register.u_IMEM.words[4] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[12'hB58] = 32'h01000093;
        dut.if_id_register.u_IMEM.words[12'hB59] = 32'h34109073;
        dut.if_id_register.u_IMEM.words[12'hB5A] = 32'h30200073;
        expect_commit(0, 32'h6D60, 32'h01000093);
        expect_commit(1, 32'h6D64, 32'h34109073);
        expect_commit(2, 32'h6D68, 32'h30200073);
        expect_commit(3, 16, 32'h00700113);
        expected_pc = 0; expected_cause = 11; check_trap = 1;
        launch(); wait_for_trap(); wait_for_commits(4);
        if (mepc_writes != 1 || mcause_writes != 1 || trap_reads != 1 ||
            trap_redirects != 1 || mret_redirects != 1 ||
            mret_commits != 1 || dut.csr_file.mepc !== 16 ||
            dut.register_file.registers[2] !== 7 ||
            dut.csr_file.minstret !== 4)
            $fatal(1, "trap-handler-MRET-resume scoreboard failure");
        $display("PASS ECALL -> handler -> MRET -> resume scoreboard");
        $display("SUMMARY: PASS 3B3 trap/ISA focused suite");
        $finish;
    end
endmodule
