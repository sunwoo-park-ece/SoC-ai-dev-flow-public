`timescale 1ns/1ps
module tb_pipeline_valid;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg reset = 1'b1;
    reg HREADY = 1'b1;
    wire [31:0] retire_instruction;
    integer cycle;
    reg [3:0] held_valid;
    reg [31:0] held_id_pc, held_ex_pc, held_mem_pc, held_wb_pc;
    reg [31:0] held_id_insn, held_ex_insn, held_mem_insn, held_wb_insn;
    reg seen_real_nop_wb = 1'b0;

    always @(posedge clk) begin
        #1;
        if (!reset && dut.WB_valid && dut.WB_pc == 32'd0 &&
            dut.WB_instruction == 32'h0000_0013)
            seen_real_nop_wb = 1'b1;
    end

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(1'b1), .reset(reset),
        .retire_instruction(retire_instruction),
        .debug_X1(), .debug_X2(), .debug_X3(), .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(), .EX_memory_write_AHB(),
        .EX_alu_result_AHB(), .EX_funct3_AHB(), .data_memory_read_data_AHB(),
        .HRDATA_FROM_AHB(32'd7), .HRESP_FROM_AHB(2'b00),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(!HREADY),
        .CUSTOM_WRITE_MASK(), .oBRAM_HAZARD()
    );

    task wait_load_use;
        begin : wait_block
            for (cycle = 0; cycle < 40; cycle = cycle + 1) begin
                @(posedge clk); #1;
                if (dut.ID_valid && dut.ID_pc == 32'd12 &&
                    dut.EX_valid && dut.EX_pc == 32'd8 &&
                    dut.IF_ID_stall && dut.ID_EX_flush) begin
                    disable wait_block;
                end
            end
            $fatal(1, "load-use stall not observed");
        end
    endtask

    task wait_redirect;
        input [31:0] expected_pc;
        input [6:0] expected_opcode;
        begin : wait_block
            for (cycle = 0; cycle < 60; cycle = cycle + 1) begin
                @(posedge clk); #1;
                if (dut.EX_valid && dut.EX_pc == expected_pc &&
                    dut.EX_opcode == expected_opcode &&
                    dut.IF_ID_flush && dut.ID_EX_flush)
                    disable wait_block;
            end
            $fatal(1, "redirect not observed at PC %0d", expected_pc);
        end
    endtask

    task check_redirect_after_edge;
        input [31:0] resolved_pc;
        input [31:0] target_pc;
        begin
            @(posedge clk); #1;
            if (dut.ID_valid !== 1'b0 || dut.EX_valid !== 1'b0 ||
                dut.MEM_valid !== 1'b1 || dut.MEM_pc !== resolved_pc)
                $fatal(1, "redirect killed wrong stages at PC %0d", resolved_pc);
            if (dut.pc !== target_pc)
                $fatal(1, "redirect PC=%0d expected=%0d", dut.pc, target_pc);
            @(posedge clk); #1;
            if (!dut.ID_valid || dut.ID_pc !== target_pc)
                $fatal(1, "stale IMEM response survived redirect at PC %0d", resolved_pc);
        end
    endtask

    initial begin
        #1;
        dut.if_id_register.u_IMEM.words[0]  = 32'h0000_0013; // real NOP
        dut.if_id_register.u_IMEM.words[1]  = 32'h1000_00b7; // lui x1,0x10000
        dut.if_id_register.u_IMEM.words[2]  = 32'h0000_a103; // lw x2,0(x1)
        dut.if_id_register.u_IMEM.words[3]  = 32'h0011_0193; // addi x3,x2,1
        dut.if_id_register.u_IMEM.words[4]  = 32'h0000_0463; // beq x0,x0,+8
        dut.if_id_register.u_IMEM.words[5]  = 32'h0090_0213; // killed x4=9
        dut.if_id_register.u_IMEM.words[6]  = 32'h0050_0293; // x5=5
        dut.if_id_register.u_IMEM.words[7]  = 32'h0080_006f; // jal x0,+8
        dut.if_id_register.u_IMEM.words[8]  = 32'h0060_0313; // killed x6=6
        dut.if_id_register.u_IMEM.words[9]  = 32'h0070_0393; // x7=7
        dut.if_id_register.u_IMEM.words[10] = 32'h0340_0413; // x8=52
        dut.if_id_register.u_IMEM.words[11] = 32'h0004_0067; // jalr x0,0(x8)
        dut.if_id_register.u_IMEM.words[12] = 32'h0090_0493; // killed x9=9
        dut.if_id_register.u_IMEM.words[13] = 32'h00a0_0513; // x10=10

        repeat (3) @(posedge clk);
        #1;
        if (dut.ID_valid || dut.EX_valid || dut.MEM_valid || dut.WB_valid)
            $fatal(1, "reset did not invalidate every pipeline stage");
        @(negedge clk); reset = 1'b0;
        @(posedge clk); #1;
        if (!dut.ID_valid || dut.ID_pc !== 32'd0 || dut.ID_instruction !== 32'h0000_0013)
            $fatal(1, "first real NOP not valid");

        wait_load_use();
        @(posedge clk); #1;
        if (dut.EX_valid !== 1'b0 || dut.EX_instruction !== 32'h0000_0013 ||
            dut.ID_valid !== 1'b1 || dut.ID_pc !== 32'd12 ||
            dut.MEM_valid !== 1'b1 || dut.MEM_pc !== 32'd8)
            $fatal(1, "load-use did not insert one invalid bubble");
        if (dut.EX_memory_read_AHB || dut.EX_memory_write_AHB || dut.EX_jump || dut.EX_branch)
            $fatal(1, "invalid load-use bubble generated a request/redirect");

        @(negedge clk); HREADY = 1'b0;
        held_valid = {dut.ID_valid, dut.EX_valid, dut.MEM_valid, dut.WB_valid};
        held_id_pc = dut.ID_pc; held_ex_pc = dut.EX_pc;
        held_mem_pc = dut.MEM_pc; held_wb_pc = dut.WB_pc;
        held_id_insn = dut.ID_instruction; held_ex_insn = dut.EX_instruction;
        held_mem_insn = dut.MEM_instruction; held_wb_insn = dut.WB_instruction;
        repeat (3) begin
            @(posedge clk); #1;
            if ({dut.ID_valid, dut.EX_valid, dut.MEM_valid, dut.WB_valid} !== held_valid ||
                dut.ID_pc !== held_id_pc || dut.EX_pc !== held_ex_pc ||
                dut.MEM_pc !== held_mem_pc || dut.WB_pc !== held_wb_pc ||
                dut.ID_instruction !== held_id_insn || dut.EX_instruction !== held_ex_insn ||
                dut.MEM_instruction !== held_mem_insn || dut.WB_instruction !== held_wb_insn)
                $fatal(1, "AHB/APB wait changed held stage token");
        end
        @(negedge clk); HREADY = 1'b1;
        @(posedge clk); #1;
        if (dut.EX_valid !== 1'b1 || dut.EX_pc !== 32'd12 ||
            dut.WB_valid !== 1'b1 || dut.WB_pc !== 32'd8)
            $fatal(1, "wait release lost/duplicated token");

        wait_redirect(32'd16, 7'h63); // taken branch
        check_redirect_after_edge(32'd16, 32'd24);
        wait_redirect(32'd28, 7'h6f); // JAL
        check_redirect_after_edge(32'd28, 32'd36);
        wait_redirect(32'd44, 7'h67); // JALR
        check_redirect_after_edge(32'd44, 32'd52);

        repeat (8) @(posedge clk);
        #1;
        if (!seen_real_nop_wb ||
            dut.register_file.registers[3] !== 32'd8 ||
            dut.register_file.registers[4] !== 32'd0 ||
            dut.register_file.registers[5] !== 32'd5 ||
            dut.register_file.registers[6] !== 32'd0 ||
            dut.register_file.registers[7] !== 32'd7 ||
            dut.register_file.registers[9] !== 32'd0 ||
            dut.register_file.registers[10] !== 32'd10)
            $fatal(1, "token execution/redirect final register state incorrect");
        $display("SUMMARY: PASS pipeline valid load-use bus-wait redirect");
        $finish;
    end
endmodule
