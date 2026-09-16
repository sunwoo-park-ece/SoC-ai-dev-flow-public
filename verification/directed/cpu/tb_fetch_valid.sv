`timescale 1ns/1ps
module tb_fetch_valid;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg clk_enable = 1'b1;
    reg reset = 1'b1;
    reg flush = 1'b0;
    reg IF_ID_stall = 1'b0;
    reg [31:0] IF_pc = 32'd0;
    wire [31:0] ID_pc;
    wire [31:0] ID_pc_plus_4;
    wire [31:0] ID_instruction;
`ifdef VALID_INFRA
    wire ID_valid;
`endif

    IF_ID_Register dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .flush(flush), .IF_ID_stall(IF_ID_stall),
        .IF_pc(IF_pc), .IF_pc_plus_4(IF_pc + 32'd4),
        .ID_pc(ID_pc), .ID_pc_plus_4(ID_pc_plus_4),
        .ID_instruction(ID_instruction)
`ifdef VALID_INFRA
        , .ID_valid(ID_valid)
`endif
    );

    task check_token;
        input [31:0] expected_pc;
        input [31:0] expected_insn;
        input expected_valid;
        input [255:0] label_text;
        begin
            if (ID_pc !== expected_pc || ID_pc_plus_4 !== expected_pc + 32'd4 ||
                ID_instruction !== expected_insn)
                $fatal(1, "%0s: pc=%08x pc4=%08x insn=%08x expected pc=%08x insn=%08x",
                       label_text, ID_pc, ID_pc_plus_4, ID_instruction,
                       expected_pc, expected_insn);
`ifdef VALID_INFRA
            if (ID_valid !== expected_valid)
                $fatal(1, "%0s: valid=%b expected=%b", label_text, ID_valid, expected_valid);
`endif
        end
    endtask

    initial begin
        #1;
        // Distinct words make every PC/instruction ownership error visible.
        dut.u_IMEM.words[0] = 32'h0000_0013; // real NOP
        dut.u_IMEM.words[1] = 32'h0010_0093;
        dut.u_IMEM.words[2] = 32'h0020_0113;
        dut.u_IMEM.words[3] = 32'h0030_0193; // stale wrong-path response
        dut.u_IMEM.words[8] = 32'h0080_0413; // redirect target

        @(posedge clk); #1;
`ifdef VALID_INFRA
        if (ID_valid !== 1'b0) $fatal(1, "reset did not invalidate fetch token");
`endif

        @(negedge clk); reset = 1'b0; IF_pc = 32'd0;
        @(posedge clk); #1; check_token(32'd0, 32'h0000_0013, 1'b1, "reset first real NOP");

        @(negedge clk); IF_pc = 32'd4;
        @(posedge clk); #1; check_token(32'd4, 32'h0010_0093, 1'b1, "sequential fetch");

        @(negedge clk); IF_ID_stall = 1'b1; IF_pc = 32'd8;
        @(posedge clk); #1; check_token(32'd4, 32'h0010_0093, 1'b1, "first stall holds old q");
        @(negedge clk); IF_pc = 32'd12;
        @(posedge clk); #1; check_token(32'd4, 32'h0010_0093, 1'b1, "multi-cycle stall");

        @(negedge clk); IF_ID_stall = 1'b0; IF_pc = 32'd8;
        @(posedge clk); #1; check_token(32'd8, 32'h0020_0113, 1'b1, "stall release");

        @(negedge clk); flush = 1'b1; IF_pc = 32'd12;
        @(posedge clk); #1;
        if (dut.irom_q !== 32'h0030_0193)
            $fatal(1, "redirect test did not create stale q");
`ifdef VALID_INFRA
        if (ID_valid !== 1'b0 || ID_instruction !== 32'h0000_0013)
            $fatal(1, "stale response became a valid token");
`else
        if (ID_instruction !== 32'h0000_0013)
            $fatal(1, "flush did not mask stale response");
`endif

        @(negedge clk); flush = 1'b0; IF_pc = 32'd32;
        @(posedge clk); #1; check_token(32'd32, 32'h0080_0413, 1'b1, "redirect target");

        @(negedge clk); clk_enable = 1'b0; IF_pc = 32'd4;
        @(posedge clk); #1; check_token(32'd32, 32'h0080_0413, 1'b1, "clock-enable hold");

        @(negedge clk); clk_enable = 1'b1;
        @(posedge clk); #1; check_token(32'd4, 32'h0010_0093, 1'b1, "clock-enable release");

        $display("SUMMARY: PASS fetch edge ownership");
        $finish;
    end
endmodule
