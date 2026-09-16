`timescale 1ns/1ps
// 3B2A A-F/L: ownership, drain, one-shot, and redirect-vs-held-CSR.
module tb_precise_ordering_csr;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg clk_enable = 1;
    reg HREADY = 1;
    wire [31:0] retire_instruction;
    integer req_count, consume_count, release_count, serial_release_count;
    integer normal_write_count, cycles, i;
    integer last_release_cycle, first_req_cycle, tick;
    reg [31:0] held_pc, held_instruction;
    reg saw_hold, saw_bubble;

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .retire_instruction(retire_instruction),
        .debug_X1(), .debug_X2(), .debug_X3(), .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(), .EX_memory_write_AHB(),
        .EX_alu_result_AHB(), .EX_funct3_AHB(), .data_memory_read_data_AHB(),
        .HRDATA_FROM_AHB(32'd17), .HRESP_FROM_AHB(2'b00),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(!HREADY),
        .CUSTOM_WRITE_MASK(), .oBRAM_HAZARD()
    );

    always @(posedge clk) if (!reset) begin
        tick = tick + 1;
        if (dut.normal_csr_req) begin
            req_count = req_count + 1;
            if (first_req_cycle < 0) first_req_cycle = tick;
            if (dut.serial_state != 2'd1 || !dut.older_empty ||
                !dut.ID_valid || dut.opcode != 7'h73 ||
                dut.EX_valid || dut.MEM_valid || dut.WB_valid)
                $fatal(1, "CSR request lacks ID owner or older drain");
        end
        if (dut.normal_csr_rsp_consume)
            consume_count = consume_count + 1;
        if (dut.WB_serial_valid && dut.wb_owner_release)
            serial_release_count = serial_release_count + 1;
        if (dut.normal_csr_write)
            normal_write_count = normal_write_count + 1;
        if (dut.wb_owner_release && dut.WB_pc < held_pc) begin
            release_count = release_count + 1;
            last_release_cycle = tick;
        end
        if (dut.csr_front_hold && dut.ID_valid && dut.ID_pc == held_pc) begin
            saw_hold = 1;
            if (dut.ID_instruction !== held_instruction || !dut.IF_ID_stall ||
                (HREADY && !dut.ID_EX_flush))
                $fatal(1, "held CSR identity/bubble unstable");
        end
        if (dut.ID_EX_flush && !dut.EX_valid) saw_bubble = 1;
        if (dut.normal_csr_req && dut.ID_instruction[6:0] != 7'h73)
            $fatal(1, "non-CSR raw bits drove request");
    end

    task prepare;
        begin
            @(negedge clk); reset = 1; clk_enable = 1; HREADY = 1;
            for (i = 0; i < 64; i = i + 1)
                dut.if_id_register.u_IMEM.words[i] = 32'h00000013;
            req_count = 0; consume_count = 0; release_count = 0;
            serial_release_count = 0; normal_write_count = 0;
            last_release_cycle = -1; first_req_cycle = -1; tick = 0;
            saw_hold = 0; saw_bubble = 0;
            repeat (3) @(posedge clk);
        end
    endtask
    task launch;
        begin @(negedge clk); reset = 0; end
    endtask
    task run_cycles(input integer count);
        begin repeat (count) @(posedge clk); #1; end
    endtask
    task assert_one_read;
        begin
            if (req_count !== 1 || consume_count !== 1 ||
                first_req_cycle <= last_release_cycle || !saw_hold || !saw_bubble)
                $fatal(1, "CSR one-shot/drain fail req=%0d consume=%0d first=%0d last=%0d hold=%0d bubble=%0d",
                       req_count, consume_count, first_req_cycle,
                       last_release_cycle, saw_hold, saw_bubble);
        end
    endtask

    initial begin
        #1;
        // A/D: one older ALU, then a read of a live counter.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093; // addi x1,x0,1
        dut.if_id_register.u_IMEM.words[1] = 32'hB02021F3; // csrrs x3,minstret,x0
        held_pc = 32'd4; held_instruction = 32'hB02021F3;
        launch();
        begin : wait_response
            for (cycles = 0; cycles < 22; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.csr_rsp_valid && dut.csr_rsp_owner == 2'b01)
                    disable wait_response;
            end
            $fatal(1, "normal CSR response never registered");
        end
        HREADY = 0;
        run_cycles(4);
        if (!dut.csr_rsp_valid || dut.csr_rsp_owner != 2'b01 ||
            dut.csr_read_out !== 1 || req_count != 1 || consume_count != 0)
            $fatal(1, "held CSR response changed or duplicated");
        @(negedge clk); HREADY = 1;
        run_cycles(22);
        assert_one_read();
        if (dut.register_file.registers[1] !== 1 ||
            dut.register_file.registers[3] !== 1)
            $fatal(1, "one-older CSR result x1=%0d x3=%0d",
                   dut.register_file.registers[1], dut.register_file.registers[3]);
        $display("PASS A/D one older and one-shot CSR");

        // B: three distinct older WB actions must precede the request.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h00200113;
        dut.if_id_register.u_IMEM.words[2] = 32'h00300213;
        dut.if_id_register.u_IMEM.words[3] = 32'hB02021F3;
        held_pc = 32'd12; held_instruction = 32'hB02021F3;
        launch(); run_cycles(30);
        assert_one_read();
        if (release_count < 3 || dut.register_file.registers[3] !== 3)
            $fatal(1, "multiple older drain count=%0d CSR=%0d",
                   release_count, dut.register_file.registers[3]);
        $display("PASS B multiple older drain");

        // C/D: an older load is stalled; the CSR identity and request stay put.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h100000B7; // lui x1,0x10000
        dut.if_id_register.u_IMEM.words[1] = 32'h0000A103; // lw x2,0(x1)
        dut.if_id_register.u_IMEM.words[2] = 32'hB02021F3;
        held_pc = 32'd8; held_instruction = 32'hB02021F3;
        launch();
        begin : wait_mem
            for (cycles = 0; cycles < 25; cycles = cycles + 1) begin
                @(negedge clk);
                if (dut.MEM_valid && dut.MEM_pc == 32'd4) disable wait_mem;
            end
            $fatal(1, "older load did not reach MEM");
        end
        HREADY = 0;
        run_cycles(4);
        if (req_count != 0 || !dut.ID_valid || dut.ID_pc != 8 ||
            dut.ID_instruction != held_instruction)
            $fatal(1, "bus wait duplicated or displaced held CSR");
        @(negedge clk); HREADY = 1;
        run_cycles(28); assert_one_read();
        if (dut.register_file.registers[2] !== 17)
            $fatal(1, "older load lost during CSR drain");
        $display("PASS C CSR behind older bus wait");

        // E: immediate bits look like CSR B02 but opcode is ADDI.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'hB0200093;
        held_pc = 32'hffff_ffff; held_instruction = 0;
        launch(); run_cycles(15);
        if (req_count || consume_count)
            $fatal(1, "non-CSR immediate issued a CSR read");
        $display("PASS E non-CSR raw address rejection");

        // F: CSRRW rd=x0 is a barrier, with no physical read.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00100093;
        dut.if_id_register.u_IMEM.words[1] = 32'h30501073;
        held_pc = 32'd4; held_instruction = 32'h30501073;
        launch(); run_cycles(27);
        if (req_count || consume_count || !saw_hold ||
            serial_release_count != 1 || normal_write_count != 1 ||
            dut.csr_file.mtvec !== 0)
            $fatal(1, "read-suppressed CSR operation failed req=%0d consume=%0d release=%0d write=%0d mtvec=%h",
                   req_count, consume_count, serial_release_count,
                   normal_write_count, dut.csr_file.mtvec);
        $display("PASS F read-suppressed CSR barrier");

        // L: an older taken branch kills the held younger CSR before issue.
        prepare();
        dut.if_id_register.u_IMEM.words[0] = 32'h00000463; // beq x0,x0,+8
        dut.if_id_register.u_IMEM.words[1] = 32'hB02021F3; // killed
        dut.if_id_register.u_IMEM.words[2] = 32'h00500293; // target
        held_pc = 32'd4; held_instruction = 32'hB02021F3;
        launch(); run_cycles(24);
        if (req_count || consume_count || dut.register_file.registers[5] !== 5)
            $fatal(1, "older branch did not kill held CSR");
        $display("PASS L branch kills held CSR");
        $display("SUMMARY: PASS 3B2A CSR ordering A-F/L");
        $finish;
    end
endmodule
