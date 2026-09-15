`include "../../vh/branch.vh"

module BranchLogic (
    input branch,
    input [31:0] src_A,
    input [31:0] src_B,
    input [2:0] funct3,
    input [31:0] pc,
    input [31:0] imm,

    output reg branch_taken,
    output reg [31:0] branch_target_actual
);

    always @(*) begin
        if (branch) begin
            case (funct3)
                `BRANCH_BEQ:  branch_taken = (src_A == src_B);
                `BRANCH_BNE:  branch_taken = (src_A != src_B);
                `BRANCH_BLT:  branch_taken = ($signed(src_A) < $signed(src_B));
                `BRANCH_BGE:  branch_taken = ($signed(src_A) >= $signed(src_B));
                `BRANCH_BLTU: branch_taken = (src_A < src_B);
                `BRANCH_BGEU: branch_taken = (src_A >= src_B);
                default:      branch_taken = 1'b0;
            endcase
            
            
            if (branch_taken) begin
                branch_target_actual = pc + imm;
            end else begin
                branch_target_actual = pc + 4;
            end
        end
        else begin
            branch_taken = 1'b0;
            branch_target_actual = 32'b0;
        end
    end

endmodule
