`timescale 1ns/1ps
// 3B2B architectural scoreboard: sampled at the WB consume edge, not WB_valid.
module tb_commit_minstret;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, clk_enable = 1, HREADY = 1;
    reg [1:0] HRESP = 0;
    integer i, ncommit, expected_count, gpr_writes, csr_writes, trap_writes;
    integer store_accepts, cycles;
    reg [31:0] expected_pc [0:15], expected_insn [0:15];
    reg [31:0] committed_pc [0:15], committed_insn [0:15];
    reg [4:0] committed_rd [0:15];
    reg committed_gpr [0:15], committed_csr [0:15];
    reg [6:0] committed_kind [0:15];
    reg committed_exception [0:15];
    reg [63:0] count_before;
    reg sampled_commit;
    reg scoreboard_enable = 0;
    wire [31:0] retire_instruction;

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .retire_instruction(retire_instruction),
        .debug_X1(), .debug_X2(), .debug_X3(), .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(), .EX_memory_write_AHB(),
        .EX_alu_result_AHB(), .EX_funct3_AHB(), .data_memory_read_data_AHB(),
        .HRDATA_FROM_AHB(32'd17), .HRESP_FROM_AHB(HRESP),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(!HREADY),
        .CUSTOM_WRITE_MASK(), .oBRAM_HAZARD()
    );

    always @(posedge clk) begin
        if (!reset && scoreboard_enable) begin
            count_before = dut.csr_file.minstret;
            sampled_commit = dut.commit_valid;
            if (sampled_commit) begin
                if (!dut.WB_valid || dut.WB_exc_valid || dut.MEM_WB_stall ||
                    dut.MEM_WB_flush || dut.wb_is_mret)
                    $fatal(1, "commit without normal WB consume");
                if (ncommit >= expected_count ||
                    dut.WB_pc !== expected_pc[ncommit] ||
                    dut.WB_instruction !== expected_insn[ncommit])
                    $fatal(1, "scoreboard[%0d] PC=%h insn=%h expected=%h/%h",
                           ncommit, dut.WB_pc, dut.WB_instruction,
                           expected_pc[ncommit], expected_insn[ncommit]);
                committed_pc[ncommit] = dut.WB_pc;
                committed_insn[ncommit] = dut.WB_instruction;
                committed_rd[ncommit] = dut.WB_rd;
                committed_gpr[ncommit] = dut.gpr_commit;
                committed_csr[ncommit] = dut.normal_csr_write;
                committed_kind[ncommit] = dut.WB_opcode;
                committed_exception[ncommit] = dut.WB_exc_valid;
                ncommit = ncommit + 1;
            end
            if (dut.gpr_commit) gpr_writes = gpr_writes + 1;
            if (dut.normal_csr_write) csr_writes = csr_writes + 1;
            if (dut.trap_wr_valid) trap_writes = trap_writes + 1;
            if (dut.MEM_valid && dut.MEM_memory_write && HREADY &&
                !dut.MEM_exc_valid && HRESP == 0)
                store_accepts = store_accepts + 1;
            if ((!sampled_commit && (dut.gpr_commit || dut.normal_csr_write)) ||
                (dut.trap_wr_valid && dut.normal_csr_write))
                $fatal(1, "side effect without owning commit");
            #1;
            if (dut.csr_file.minstret !== count_before + sampled_commit)
                $fatal(1, "minstret delta mismatch before=%0d after=%0d commit=%0d",
                       count_before, dut.csr_file.minstret, sampled_commit);
        end
    end

    task prepare(input integer count);
        begin
            scoreboard_enable = 0;
            @(negedge clk); reset = 1;
            clk_enable = 1; HREADY = 1; HRESP = 0;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = 0;
            for (i = 0; i < 64; i = i + 1)
                dut.if_id_register.u_IMEM.words[i] = 32'h00000073;
            expected_count = count; ncommit = 0; gpr_writes = 0;
            csr_writes = 0; trap_writes = 0; store_accepts = 0;
            repeat (3) @(posedge clk);
        end
    endtask
    task expect_token(input integer idx, input [31:0] pc, input [31:0] insn);
        begin expected_pc[idx] = pc; expected_insn[idx] = insn; end
    endtask
    task launch;
        begin @(negedge clk); reset = 0; scoreboard_enable = 1; end
    endtask
    task wait_commits;
        begin : waiting
            for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
                @(negedge clk);
                if (ncommit == expected_count) disable waiting;
            end
            $fatal(1, "commit timeout %0d/%0d", ncommit, expected_count);
        end
    endtask

    initial begin
        #1;
        // A/B/N: ALU, real NOP, CSRRS minstret. Read includes both older
        // tokens and excludes the CSR instruction itself.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000013;
        dut.if_id_register.u_IMEM.words[2] = 32'hB02021F3;
        expect_token(0, 0, 32'h00100093); expect_token(1, 4, 32'h00000013);
        expect_token(2, 8, 32'hB02021F3);
        launch(); wait_commits();
        if (dut.register_file.registers[3] !== 2 ||
            dut.csr_file.minstret !== 3 || committed_gpr[1])
            $fatal(1, "real NOP/CSR count failure");
        $display("PASS A/B/N ALU, real NOP, bubble, CSR observation");

        // B/N: mixed ALU + real NOP + load before minstret read. Only
        // those three valid older tokens are visible to the CSR read.
        prepare(4);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100213;
        dut.if_id_register.u_IMEM.words[1] = 32'h00000013;
        dut.if_id_register.u_IMEM.words[2] = 32'h00002103;
        dut.if_id_register.u_IMEM.words[3] = 32'hB02021F3;
        expect_token(0, 0, 32'h00100213);
        expect_token(1, 4, 32'h00000013);
        expect_token(2, 8, 32'h00002103);
        expect_token(3, 12, 32'hB02021F3);
        launch(); wait_commits();
        if (dut.register_file.registers[3] !== 3 ||
            dut.csr_file.minstret !== 4 || committed_exception[2])
            $fatal(1, "mixed older sequence/minstret read mismatch");
        $display("PASS B/N ALU, real NOP, load, minstret read");

        // C/E: load-use inserts an invalid bubble; successful load and
        // dependent ALU each retire exactly once.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h100000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h0000A103;
        dut.if_id_register.u_IMEM.words[2] = 32'h00110193;
        expect_token(0, 0, 32'h100000B7); expect_token(1, 4, 32'h0000A103);
        expect_token(2, 8, 32'h00110193);
        launch(); wait_commits();
        if (dut.register_file.registers[2] !== 17 ||
            dut.register_file.registers[3] !== 18 ||
            dut.csr_file.minstret !== 3)
            $fatal(1, "load-use scoreboard failure");
        $display("PASS C/E load-use, successful load, invalid bubble");

        // D/Q: older WB held by a younger bus wait, then clk_enable hold.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h500000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[2] = 32'h0000A183;
        expect_token(0, 0, 32'h500000B7);
        expect_token(1, 4, 32'h00700113);
        expect_token(2, 8, 32'h0000A183);
        launch();
        begin : wait_older
            for (cycles = 0; cycles < 25; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.WB_valid && dut.WB_pc == 4 &&
                    dut.MEM_valid && dut.MEM_pc == 8 && dut.MEM_memory_read)
                    disable wait_older;
            end
            $fatal(1, "older WB/younger MEM overlap absent");
        end
        HREADY = 0;
        repeat (4) begin
            @(negedge clk);
            if (ncommit != 1 || dut.commit_valid || dut.gpr_commit)
                $fatal(1, "held WB committed");
        end
        clk_enable = 0; HREADY = 1;
        repeat (3) begin
            @(negedge clk);
            if (ncommit != 1 || dut.commit_valid || dut.gpr_commit)
                $fatal(1, "disabled WB committed");
        end
        clk_enable = 1; wait_commits();
        if (dut.csr_file.minstret !== 3 || gpr_writes != 3 ||
            dut.csr_file.mcycle <= dut.csr_file.minstret)
            $fatal(1, "WB release/mcycle divergence failure");
        $display("PASS D/Q held WB, clk_enable, mcycle independence");

        // G: store has no GPR write but retires at WB once.
        prepare(2);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100113;
        dut.if_id_register.u_IMEM.words[1] = 32'h00202023;
        expect_token(0, 0, 32'h00100113); expect_token(1, 4, 32'h00202023);
        launch(); wait_commits();
        if (store_accepts != 1 || gpr_writes != 1 ||
            dut.csr_file.minstret !== 2)
            $fatal(1, "successful store retirement mismatch");
        $display("PASS G successful store");

        // O/P: CSR write and back-to-back read serialize; write occurs
        // only on first CSR's architectural commit.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h30509173; // csrrw x2,mtvec,x1
        dut.if_id_register.u_IMEM.words[2] = 32'h305021F3; // csrrs x3,mtvec,x0
        expect_token(0, 0, 32'h00100093); expect_token(1, 4, 32'h30509173);
        expect_token(2, 8, 32'h305021F3);
        launch(); wait_commits();
        if (dut.register_file.registers[2] !== 32'h00006d60 ||
            dut.register_file.registers[3] !== 1 ||
            dut.csr_file.mtvec !== 1 || csr_writes != 1 ||
            dut.csr_file.minstret !== 3)
            $fatal(1, "CSR commit/serialization mismatch old=%h new=%h writes=%0d",
                   dut.register_file.registers[2], dut.register_file.registers[3], csr_writes);
        $display("PASS O/P normal CSR write and back-to-back CSR");

        // J: not-taken branch is still a normal WB retirement token.
        prepare(2);
        dut.if_id_register.u_IMEM.words[0] = 32'h00001463; // bne x0,x0,+8
        dut.if_id_register.u_IMEM.words[1] = 32'h00500293;
        expect_token(0, 0, 32'h00001463);
        expect_token(1, 4, 32'h00500293);
        launch(); wait_commits();
        if (dut.register_file.registers[5] !== 5 ||
            dut.csr_file.minstret !== 2)
            $fatal(1, "not-taken branch retirement mismatch");
        $display("PASS J not-taken branch");

        // K: taken redirect kills younger PC4, not the branch itself.
        prepare(2);
        dut.if_id_register.u_IMEM.words[0] = 32'h00000463; // beq x0,x0,+8
        dut.if_id_register.u_IMEM.words[1] = 32'h00900293;
        dut.if_id_register.u_IMEM.words[2] = 32'h00700313;
        expect_token(0, 0, 32'h00000463);
        expect_token(1, 8, 32'h00700313);
        launch(); wait_commits();
        if (dut.register_file.registers[5] !== 0 ||
            dut.register_file.registers[6] !== 7)
            $fatal(1, "taken branch retirement/kill mismatch");
        $display("PASS K taken branch");

        // L: JAL retires once and writes one link value.
        prepare(2);
        dut.if_id_register.u_IMEM.words[0] = 32'h0080026F; // jal x4,+8
        dut.if_id_register.u_IMEM.words[1] = 32'h00900293;
        dut.if_id_register.u_IMEM.words[2] = 32'h00700313;
        expect_token(0, 0, 32'h0080026F);
        expect_token(1, 8, 32'h00700313);
        launch(); wait_commits();
        if (dut.register_file.registers[4] !== 4 ||
            dut.register_file.registers[5] !== 0 || gpr_writes != 2)
            $fatal(1, "JAL link or killed token mismatch");
        $display("PASS L JAL");

        // M: supported aligned JALR case; full target semantics are 3B3.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h01000093; // addi x1,x0,16
        dut.if_id_register.u_IMEM.words[1] = 32'h000082E7; // jalr x5,0(x1)
        dut.if_id_register.u_IMEM.words[2] = 32'h00900313;
        dut.if_id_register.u_IMEM.words[4] = 32'h00700393;
        expect_token(0, 0, 32'h01000093);
        expect_token(1, 4, 32'h000082E7);
        expect_token(2, 16, 32'h00700393);
        launch(); wait_commits();
        if (dut.register_file.registers[5] !== 8 ||
            dut.register_file.registers[6] !== 0 ||
            dut.register_file.registers[7] !== 7)
            $fatal(1, "JALR link/target mismatch");
        $display("PASS M aligned JALR");

        // S: reset kills a held, unconsumed WB token. A fresh post-reset
        // execution may commit the same program PC once, never twice.
        prepare(3);
        dut.if_id_register.u_IMEM.words[0] = 32'h500000B7;
        dut.if_id_register.u_IMEM.words[1] = 32'h00700113;
        dut.if_id_register.u_IMEM.words[2] = 32'h0000A183;
        expect_token(0, 0, 32'h500000B7);
        expect_token(1, 4, 32'h00700113);
        expect_token(2, 8, 32'h0000A183);
        launch();
        begin : wait_reset_hold
            for (cycles = 0; cycles < 25; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.WB_valid && dut.WB_pc == 4 &&
                    dut.MEM_valid && dut.MEM_pc == 8 && dut.MEM_memory_read)
                    disable wait_reset_hold;
            end
            $fatal(1, "reset test held WB overlap absent");
        end
        HREADY = 0;
        repeat (2) @(negedge clk);
        if (ncommit != 1 || dut.commit_valid)
            $fatal(1, "pre-reset held token committed");
        reset = 1; scoreboard_enable = 0;
        repeat (3) @(posedge clk);
        #1;
        if (dut.WB_valid || dut.commit_valid || dut.csr_file.minstret !== 0)
            $fatal(1, "reset left retirement state active");
        ncommit = 0; gpr_writes = 0; HREADY = 1;
        launch(); wait_commits();
        if (dut.csr_file.minstret !== 3 || gpr_writes != 3)
            $fatal(1, "post-reset token did not commit exactly once");
        $display("PASS S reset around held WB token");

        $display("SUMMARY: PASS 3B2B normal architectural scoreboard");
        $finish;
    end
endmodule
