`timescale 1ns/1ps
module tb_mepc_storage;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg normal_req_valid = 0, trap_req_valid = 0, mret_req_valid = 0;
    reg rsp_consume = 0, normal_wr_valid = 0, trap_wr_valid = 0;
    reg [11:0] normal_wr_addr = 12'h341, trap_wr_addr = 12'h341;
    reg [31:0] normal_wr_data = 0, trap_wr_data = 0;
    wire [31:0] csr_read_out;
    wire csr_rsp_valid;
    wire [1:0] csr_rsp_owner;
    integer low_bits;

    CSRFile dut (
        .clk(clk), .clk_enable(1'b1), .reset(reset),
        .normal_req_valid(normal_req_valid), .normal_req_addr(12'h341),
        .trap_req_valid(trap_req_valid), .trap_req_addr(12'h341),
        .mret_req_valid(mret_req_valid), .mret_req_addr(12'h341),
        .rsp_consume(rsp_consume),
        .normal_wr_valid(normal_wr_valid), .normal_wr_addr(normal_wr_addr),
        .normal_wr_data(normal_wr_data),
        .trap_wr_valid(trap_wr_valid), .trap_wr_addr(trap_wr_addr),
        .trap_wr_data(trap_wr_data), .commit_valid(1'b0),
        .csr_read_out(csr_read_out), .csr_rsp_valid(csr_rsp_valid),
        .csr_rsp_owner(csr_rsp_owner)
    );

    task read_mepc(input [31:0] expected);
        begin
            @(negedge clk); normal_req_valid = 1;
            @(negedge clk); normal_req_valid = 0;
            if (!csr_rsp_valid || csr_rsp_owner !== 2'b01 ||
                csr_read_out !== expected)
                $fatal(1, "mepc readback got=%h expected=%h", csr_read_out, expected);
            rsp_consume = 1;
            @(negedge clk); rsp_consume = 0;
        end
    endtask

    task normal_write(input [31:0] raw);
        begin
            @(negedge clk); normal_wr_data = raw; normal_wr_valid = 1;
            @(negedge clk); normal_wr_valid = 0;
            if (dut.mepc !== {raw[31:2], 2'b00})
                $fatal(1, "normal mepc storage mismatch raw=%h got=%h",
                       raw, dut.mepc);
            read_mepc({raw[31:2], 2'b00});
        end
    endtask

    task trap_write(input [31:0] raw);
        begin
            @(negedge clk); trap_wr_data = raw; trap_wr_valid = 1;
            @(negedge clk); trap_wr_valid = 0;
            if (dut.mepc !== {raw[31:2], 2'b00})
                $fatal(1, "trap mepc storage mismatch raw=%h got=%h",
                       raw, dut.mepc);
            read_mepc({raw[31:2], 2'b00});
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        for (low_bits = 0; low_bits < 4; low_bits = low_bits + 1) begin
            normal_write(32'h00000010 + low_bits);
            trap_write(32'h12345678 + low_bits);
        end
        normal_write(32'h1234567B);
        // Preserve existing trap-writer priority when both request the
        // same storage register on one edge.
        @(negedge clk);
        normal_wr_data = 32'h00000013; normal_wr_valid = 1;
        trap_wr_data = 32'h00000021; trap_wr_valid = 1;
        @(negedge clk);
        normal_wr_valid = 0; trap_wr_valid = 0;
        if (dut.mepc !== 32'h00000020)
            $fatal(1, "trap-writer priority/canonicalization failed");
        read_mepc(32'h00000020);
        $display("SUMMARY: PASS mepc normal/trap storage and CSR readback");
        $finish;
    end
endmodule
